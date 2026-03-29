# Blip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a production-grade iOS BLE mesh chat app for festivals with E2E encryption, 4 crowd-scale modes, medical SOS, friend finder, and glassmorphism UI.

**Architecture:** Pure Swift, 3 SPM packages (Protocol, Mesh, Crypto) + SwiftUI MVVM app. BLE mesh primary transport, WebSocket fallback. SwiftData persistence. StoreKit 2 monetization.

**Tech Stack:** Swift 5.9+, SwiftUI, SwiftData, CoreBluetooth, CryptoKit, swift-sodium, swift-opus, MapKit, StoreKit 2, XcodeGen

**Spec:** `docs/superpowers/specs/2026-03-28-blip-design.md`

---

## Phase 1: Project Scaffold & Design System (Foundation)

### Task 1.1: XcodeGen Project Configuration

**Files:**
- Create: `project.yml`
- Create: `.gitignore`
- Create: `App/BlipApp.swift`
- Create: `App/Info.plist`
- Create: `App/Entitlements/Blip.entitlements`

- [ ] **Step 1: Create `.gitignore` for Swift/Xcode**

```gitignore
# Xcode
*.xcodeproj/xcuserdata/
*.xcworkspace/xcuserdata/
DerivedData/
build/
*.pbxproj
*.xcuserstate

# Swift Package Manager
.build/
Packages/*/Package.resolved

# macOS
.DS_Store

# Secrets
*.env
*.key
```

- [ ] **Step 2: Create `project.yml` for XcodeGen**

Defines the full project: iOS 16.0 deployment target, Swift 5.9, 3 local SPM packages, all capabilities (BLE, push, IAP, Keychain, location), debug/release schemes with separate BLE UUIDs.

- [ ] **Step 3: Create `App/BlipApp.swift`**

Minimal `@main` entry point with SwiftData model container, environment setup.

- [ ] **Step 4: Create `App/Info.plist`**

BLE background modes, location usage descriptions, custom fonts registration (Plus Jakarta Sans), camera/photo library usage.

- [ ] **Step 5: Create entitlements file**

Background Modes (bluetooth-central, bluetooth-peripheral, audio), Keychain Sharing, In-App Purchase, Push Notifications.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "chore: scaffold Xcode project with XcodeGen"
```

### Task 1.2: Design System — Colors, Typography, Theme

**Files:**
- Create: `Sources/DesignSystem/Theme.swift`
- Create: `Sources/DesignSystem/Colors.swift`
- Create: `Sources/DesignSystem/Typography.swift`
- Create: `Sources/DesignSystem/Spacing.swift`
- Create: `App/Assets.xcassets/Colors/AccentPurple.colorset/Contents.json`
- Create: `App/Assets.xcassets/Colors/Background.colorset/Contents.json`
- Create: `App/Assets.xcassets/Colors/CardBG.colorset/Contents.json`
- Create: `App/Assets.xcassets/Colors/MutedText.colorset/Contents.json`
- Create: `App/Assets.xcassets/Colors/Border.colorset/Contents.json`
- Create: `App/Assets.xcassets/Colors/Hover.colorset/Contents.json`
- Create: `Resources/Fonts/PlusJakartaSans-Regular.ttf` (placeholder, user provides)
- Create: `Resources/Fonts/PlusJakartaSans-Medium.ttf`
- Create: `Resources/Fonts/PlusJakartaSans-SemiBold.ttf`
- Create: `Resources/Fonts/PlusJakartaSans-Bold.ttf`

- [ ] **Step 1: Create `Colors.swift`**

Define all color tokens as `Color` extensions with light/dark variants:
- `.fcBackground`, `.fcText`, `.fcMutedText`, `.fcBorder`, `.fcCardBG`, `.fcHover`, `.fcAccentPurple`
- Dark: `#000000` bg, `#FFFFFF` text, `rgba(255,255,255,0.5)` muted, `#6600FF` accent
- Light: `#FFFFFF` bg, `#000000` text, `rgba(0,0,0,0.5)` muted, `#6600FF` accent

- [ ] **Step 2: Create `Typography.swift`**

Register Plus Jakarta Sans fonts. Define text styles:
- `.fcLargeTitle` (Bold, 34pt), `.fcHeadline` (SemiBold, 22pt), `.fcBody` (Regular, 17pt), `.fcSecondary` (Regular, 13pt), `.fcCaption` (Medium, 11pt)

- [ ] **Step 3: Create `Spacing.swift`**

Spacing scale: `xs: 4`, `sm: 8`, `md: 16`, `lg: 24`, `xl: 32`, `xxl: 48`

- [ ] **Step 4: Create `Theme.swift`**

Unified theme object combining colors, typography, spacing. Environment key for injection.

- [ ] **Step 5: Create Asset Catalog color sets**

JSON colorset files for each named color with light/dark appearances.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(design): add design system — colors, typography, spacing, theme"
```

### Task 1.3: Design System — Glass Components & Animations

**Files:**
- Create: `Sources/DesignSystem/GlassCard.swift`
- Create: `Sources/DesignSystem/GradientBackground.swift`
- Create: `Sources/DesignSystem/GlassButton.swift`
- Create: `Sources/Animations/StaggeredReveal.swift`
- Create: `Sources/Animations/ScrollReveal.swift`
- Create: `Sources/Animations/SpringConstants.swift`
- Create: `Sources/Animations/RippleEffect.swift`
- Create: `Sources/Animations/MorphingIcon.swift`

- [ ] **Step 1: Create `GlassCard.swift`**

Reusable glass material container with `.thickMaterial`, `cornerRadius(24)`, 0.5pt border at 20% opacity. Configurable material thickness.

- [ ] **Step 2: Create `GradientBackground.swift`**

Animated mesh gradient background. Slow shift between deep purple, midnight blue, dark teal. Respects `UIAccessibility.isReduceMotionEnabled`.

- [ ] **Step 3: Create `GlassButton.swift`**

Glass-styled button with accent purple gradient. Hover/press states.

- [ ] **Step 4: Create `SpringConstants.swift`**

Shared spring configs: `stiffness: 300, damping: 24` for page entrances. `stiffness: 200, damping: 20` for messages. `cubic-bezier(0.16, 1, 0.3, 1)` for reveals.

- [ ] **Step 5: Create `StaggeredReveal.swift`**

ViewModifier for staggered list item reveals. Fade + translateY, 50ms stagger. Reduced motion: simple fade.

- [ ] **Step 6: Create `ScrollReveal.swift`**

ViewModifier using `onAppear` / geometry reader for scroll-triggered reveals. Fade + translateY(20px).

- [ ] **Step 7: Create `RippleEffect.swift`**

Expanding concentric ring animation for PTT. Configurable ring count, speed, color.

- [ ] **Step 8: Create `MorphingIcon.swift`**

Shape interpolation between mic icon and send arrow. Triggered by text field content.

- [ ] **Step 9: Commit**

```bash
git commit -m "feat(design): add glass components and animation system"
```

---

## Phase 2: Protocol Package (Binary Wire Format)

### Task 2.1: Packet Header & Core Types

**Files:**
- Create: `Packages/BlipProtocol/Package.swift`
- Create: `Packages/BlipProtocol/Sources/Packet.swift`
- Create: `Packages/BlipProtocol/Sources/MessageType.swift`
- Create: `Packages/BlipProtocol/Sources/PacketFlags.swift`
- Create: `Packages/BlipProtocol/Sources/PeerID.swift`
- Test: `Packages/BlipProtocol/Tests/PacketTests.swift`

- [ ] **Step 1: Create `Package.swift`**

SPM package definition. Name: `BlipProtocol`. Swift 5.9. No external dependencies.

- [ ] **Step 2: Write failing test for packet header serialization**

Test encoding a packet header to 16 bytes and decoding it back. Verify version, type, TTL, timestamp, flags, payload length round-trip correctly in big-endian.

- [ ] **Step 3: Implement `MessageType.swift`**

`enum MessageType: UInt8` with all 0x01-0x53 values from spec Section 6.4.

- [ ] **Step 4: Implement `PacketFlags.swift`**

`struct PacketFlags: OptionSet` with `hasRecipient`, `hasSignature`, `isCompressed`, `hasRoute`, `isReliable`, `isPriority`.

- [ ] **Step 5: Implement `PeerID.swift`**

8-byte peer identifier. `Hashable`, `Codable`, `Equatable`. Factory method from Noise public key (`SHA256(key)[0..<8]`). Broadcast constant `0xFFFFFFFFFFFFFFFF`.

- [ ] **Step 6: Implement `Packet.swift`**

`struct Packet` with header fields + sender ID + optional recipient ID + payload + optional signature. `serialize() -> Data` and `static func deserialize(from: Data) -> Packet`. Big-endian encoding. Validate header size (16 bytes).

- [ ] **Step 7: Run tests, verify pass**

```bash
swift test --package-path Packages/BlipProtocol
```

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(protocol): implement packet header, message types, flags, peer ID"
```

### Task 2.2: Packet Serializer & Validator

**Files:**
- Create: `Packages/BlipProtocol/Sources/PacketSerializer.swift`
- Create: `Packages/BlipProtocol/Sources/PacketValidator.swift`
- Create: `Packages/BlipProtocol/Sources/EncryptedSubType.swift`
- Test: `Packages/BlipProtocol/Tests/PacketSerializerTests.swift`

- [ ] **Step 1: Write failing tests**

Test full packet serialization: header + sender + recipient + payload + signature. Test packets with various flag combinations. Test max payload arithmetic (416 bytes addressed+signed, 424 broadcast+signed, 480 addressed+unsigned, 488 broadcast+unsigned).

- [ ] **Step 2: Implement `PacketSerializer.swift`**

Static methods: `encode(packet:) -> Data` and `decode(data:) -> Packet`. Handles all flag-dependent variable fields. Validates size constraints.

- [ ] **Step 3: Implement `PacketValidator.swift`**

Validate packet integrity: version check, type is known, TTL in range 0-7, payload length matches actual, timestamp not future (with 30s tolerance).

- [ ] **Step 4: Implement `EncryptedSubType.swift`**

`enum EncryptedSubType: UInt8` with all 0x01-0x16 values from spec Section 6.5.

- [ ] **Step 5: Run tests, verify pass**

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(protocol): add packet serializer, validator, encrypted sub-types"
```

### Task 2.3: TLV Encoding, Compression, Padding

**Files:**
- Create: `Packages/BlipProtocol/Sources/TLVEncoder.swift`
- Create: `Packages/BlipProtocol/Sources/Compression.swift`
- Create: `Packages/BlipProtocol/Sources/Padding.swift`
- Test: `Packages/BlipProtocol/Tests/TLVTests.swift`
- Test: `Packages/BlipProtocol/Tests/CompressionTests.swift`

- [ ] **Step 1: Write failing tests for TLV**

Test encoding username + public keys + capabilities into TLV. Decode back. Verify field ordering and lengths.

- [ ] **Step 2: Implement `TLVEncoder.swift`**

Type-Length-Value encoder/decoder. Types: `username(1)`, `noiseKey(2)`, `signingKey(3)`, `capabilities(4)`, `neighbors(5)`, `avatarHash(6)`. Length is UInt16 big-endian. Value is raw bytes.

- [ ] **Step 3: Write failing tests for compression**

Test: payload < 100 bytes �� no compression. 100-256 → compress if smaller. > 256 → always compress. Pre-compressed data → skip.

- [ ] **Step 4: Implement `Compression.swift`**

Uses Apple's built-in `compression` framework with zlib (Algorithm.zlib). `compress(data:) -> Data?` and `decompress(data:) -> Data?`.

- [ ] **Step 5: Write failing tests for padding**

Test: packets padded to nearest 256/512/1024/2048 boundary using PKCS#7.

- [ ] **Step 6: Implement `Padding.swift`**

PKCS#7 padding to block boundaries. `pad(data:) -> Data` and `unpad(data:) -> Data`.

- [ ] **Step 7: Run all tests, verify pass**

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(protocol): add TLV encoding, zlib compression, PKCS#7 padding"
```

### Task 2.4: Fragmentation & Bloom Filter

**Files:**
- Create: `Packages/BlipProtocol/Sources/FragmentSplitter.swift`
- Create: `Packages/BlipProtocol/Sources/FragmentAssembler.swift`
- Create: `Packages/BlipProtocol/Sources/BloomFilter.swift`
- Create: `Packages/BlipProtocol/Sources/GCSFilter.swift`
- Test: `Packages/BlipProtocol/Tests/FragmentTests.swift`
- Test: `Packages/BlipProtocol/Tests/BloomFilterTests.swift`

- [ ] **Step 1: Write failing tests for fragmentation**

Test splitting a 2KB payload into fragments at 416-byte threshold. Verify fragment headers (fragmentID, index, total). Test reassembly from out-of-order fragments. Test timeout after 30 seconds.

- [ ] **Step 2: Implement `FragmentSplitter.swift`**

Split payload into fragments. Each fragment: `fragmentID (4 bytes UUID prefix) + index (UInt16) + total (UInt16) + data`. Max 128 concurrent assemblies.

- [ ] **Step 3: Implement `FragmentAssembler.swift`**

Reassemble fragments by fragmentID. Track received indices. Complete when all fragments received. Timeout: 30 seconds. Max 128 concurrent assemblies, LRU eviction.

- [ ] **Step 4: Write failing tests for Bloom filter**

Test: insert 1000 packet IDs, check membership. Verify false positive rate < 1%. Test double-hashing (two independent hash functions). Test 3-tier rolling (hot/warm/cold).

- [ ] **Step 5: Implement `BloomFilter.swift`**

Multi-tier Bloom filter. Hot (4KB, 60s), Warm (16KB, 10m), Cold (64KB, 2h). Double-hashing with two independent hash functions. Roll tiers on timer. `insert(packetID:)`, `contains(packetID:) -> Bool`.

- [ ] **Step 6: Implement `GCSFilter.swift`**

Golomb-Coded Set for sync. `encode(messageIDs:) -> Data` (max 400 bytes). `decode(data:) -> Set<Data>`. Target false positive: 1%.

- [ ] **Step 7: Run all tests, verify pass**

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(protocol): add fragmentation, bloom filter, GCS sync"
```

---

## Phase 3: Crypto Package

### Task 3.1: Key Management & Keychain

**Files:**
- Create: `Packages/BlipCrypto/Package.swift`
- Create: `Packages/BlipCrypto/Sources/KeyManager.swift`
- Create: `Packages/BlipCrypto/Sources/Signer.swift`
- Create: `Packages/BlipCrypto/Sources/PhoneHasher.swift`
- Test: `Packages/BlipCrypto/Tests/KeyManagerTests.swift`
- Test: `Packages/BlipCrypto/Tests/SignerTests.swift`

- [ ] **Step 1: Create `Package.swift`**

Dependencies: CryptoKit (Apple), swift-sodium for Ed25519.

- [ ] **Step 2: Write failing tests for key generation and storage**

Test: generate Curve25519 keypair, store in Keychain, retrieve. Generate Ed25519 keypair, store, retrieve. Derive PeerID from Noise public key.

- [ ] **Step 3: Implement `KeyManager.swift`**

Generate and store Curve25519 (Noise) and Ed25519 (signing) keypairs in iOS Keychain. `kSecAttrAccessibleAfterFirstUnlock`. Methods: `generateIdentity()`, `loadIdentity() -> Identity?`, `exportRecoveryKit(password:) -> Data`, `importRecoveryKit(data:password:)`.

- [ ] **Step 4: Write failing tests for signing**

Test: sign packet data (excluding TTL), verify signature. Test invalid signature rejection. Test that TTL changes don't invalidate signature.

- [ ] **Step 5: Implement `Signer.swift`**

Ed25519 sign/verify via swift-sodium. `sign(packet:privateKey:) -> Data` (64 bytes). `verify(packet:signature:publicKey:) -> Bool`. Excludes TTL byte (offset 2) from signed data.

- [ ] **Step 6: Implement `PhoneHasher.swift`**

`hash(phone:salt:) -> Data` using `SHA256(phone_e164 + salt)`. `generateSalt() -> Data` (32 random bytes).

- [ ] **Step 7: Run tests, verify pass**

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(crypto): add key management, Ed25519 signing, phone hashing"
```

### Task 3.2: Noise Protocol Implementation

**Files:**
- Create: `Packages/BlipCrypto/Sources/NoiseHandshake.swift`
- Create: `Packages/BlipCrypto/Sources/NoiseCipherState.swift`
- Create: `Packages/BlipCrypto/Sources/NoiseSessionManager.swift`
- Create: `Packages/BlipCrypto/Sources/ReplayProtection.swift`
- Create: `Packages/BlipCrypto/Sources/SenderKeyManager.swift`
- Test: `Packages/BlipCrypto/Tests/NoiseHandshakeTests.swift`
- Test: `Packages/BlipCrypto/Tests/ReplayProtectionTests.swift`

- [ ] **Step 1: Write failing tests for Noise XX handshake**

Test: initiator and responder complete 3-message XX handshake. Verify bidirectional encryption works after handshake. Verify mutual authentication.

- [ ] **Step 2: Implement `NoiseHandshake.swift`**

`Noise_XX_25519_ChaChaPoly_SHA256` state machine. Three phases: `writeMessage1()`, `readMessage1()/writeMessage2()`, `readMessage2()/writeMessage3()`, `readMessage3()`. Returns `NoiseCipherState` pair on completion. Uses CryptoKit Curve25519 for DH, ChaChaPoly for AEAD, SHA256 for hashing.

- [ ] **Step 3: Implement `NoiseCipherState.swift`**

Symmetric cipher state for send/receive after handshake. `encrypt(plaintext:) -> Data` and `decrypt(ciphertext:) -> Data`. 64-bit nonce counter. ChaChaPoly AEAD.

- [ ] **Step 4: Write failing tests for replay protection**

Test: nonce window accepts in-order nonces. Rejects duplicate nonces. Accepts out-of-order within window (128-bit). Rejects nonces older than window.

- [ ] **Step 5: Implement `ReplayProtection.swift`**

Sliding window nonce tracker. 64-bit counter + 128-bit window bitmap. `accept(nonce:) -> Bool`.

- [ ] **Step 6: Implement `NoiseSessionManager.swift`**

Manage active sessions keyed by PeerID. Session caching (4 hours). IK pattern upgrade for known peers. Re-key after 1000 messages or 1 hour. `getOrCreateSession(peerID:)`, `destroySession(peerID:)`.

- [ ] **Step 7: Implement `SenderKeyManager.swift`**

AES-256-GCM sender keys for groups. Generate, distribute (via pairwise Noise), rotate on member change/100 messages. `createKey(forChannel:) -> GroupSenderKey`, `rotateKey(forChannel:reason:)`.

- [ ] **Step 8: Run all tests, verify pass**

- [ ] **Step 9: Commit**

```bash
git commit -m "feat(crypto): add Noise XX handshake, cipher state, session manager, sender keys"
```

---

## Phase 4: Mesh Networking Package

### Task 4.1: Transport Protocol & BLE Service

**Files:**
- Create: `Packages/BlipMesh/Package.swift`
- Create: `Packages/BlipMesh/Sources/Transport.swift`
- Create: `Packages/BlipMesh/Sources/BLEConstants.swift`
- Create: `Packages/BlipMesh/Sources/BLEService.swift`
- Create: `Packages/BlipMesh/Sources/PeerManager.swift`
- Test: `Packages/BlipMesh/Tests/PeerManagerTests.swift`

- [ ] **Step 1: Create `Package.swift`**

Dependencies: BlipProtocol, BlipCrypto (local packages).

- [ ] **Step 2: Implement `Transport.swift`**

Protocol definition:
```swift
protocol Transport: AnyObject {
    var delegate: TransportDelegate? { get set }
    func start()
    func stop()
    func send(data: Data, to peerID: PeerID)
    func broadcast(data: Data)
    var connectedPeers: [PeerID] { get }
}
```

- [ ] **Step 3: Implement `BLEConstants.swift`**

Service UUID, characteristic UUID, debug UUIDs, MTU values, timeout constants.

- [ ] **Step 4: Implement `BLEService.swift`**

Dual-role BLE: `CBCentralManager` + `CBPeripheralManager`. Scan for service UUID, connect, subscribe to characteristic. Advertise service UUID, accept connections. State restoration IDs. Background mode support. Delegate callbacks for data received, peer connected/disconnected.

- [ ] **Step 5: Implement `PeerManager.swift`**

Track discovered peers. `PeripheralState` struct (peripheral, characteristic, peerID, connection state, RSSI, last seen). Bidirectional peer-to-UUID mapping. Score-based peer selection (RSSI sweet spot, diversity, stability, bridge status). 30-second evaluation interval. 20% hysteresis for swaps.

- [ ] **Step 6: Run tests, commit**

```bash
git commit -m "feat(mesh): add transport protocol, BLE service, peer manager"
```

### Task 4.2: Gossip Router & Store-Forward

**Files:**
- Create: `Packages/BlipMesh/Sources/GossipRouter.swift`
- Create: `Packages/BlipMesh/Sources/StoreForwardCache.swift`
- Create: `Packages/BlipMesh/Sources/AdaptiveRelay.swift`
- Create: `Packages/BlipMesh/Sources/DirectedRouter.swift`
- Test: `Packages/BlipMesh/Tests/GossipRouterTests.swift`

- [ ] **Step 1: Write failing tests for gossip routing**

Test: packet received → check Bloom → add → decrement TTL → relay to peers except source. Test TTL 0 drops. Test Bloom dedup. Test relay probability calculation.

- [ ] **Step 2: Implement `GossipRouter.swift`**

Core routing engine. Receives packets, checks Bloom filter, decrements TTL, relays with probability. Priority-aware: SOS always relayed. Excludes source peer from relay set.

- [ ] **Step 3: Implement `StoreForwardCache.swift`**

Tiered caching: DMs 2hr, groups 30min, channels 5min, announcements 1hr, SOS until resolved. LRU eviction when cache exceeds 10MB. `cache(packet:)`, `retrieve(forPeerID:) -> [Packet]`.

- [ ] **Step 4: Implement `AdaptiveRelay.swift`**

Relay probability formula: `P = base × urgency × freshness × congestion`. Jitter: 8-25ms random delay. High-degree threshold: 6 peers triggers probabilistic relay.

- [ ] **Step 5: Implement `DirectedRouter.swift`**

Routing table from announcement neighbor lists. `updateRoute(peerID:viaPeer:)`. `findRoute(to:) -> PeerID?`. Entries expire after 5 minutes. Fallback to gossip.

- [ ] **Step 6: Run tests, commit**

```bash
git commit -m "feat(mesh): add gossip router, store-forward cache, adaptive relay, directed routing"
```

### Task 4.3: Congestion Management & Power

**Files:**
- Create: `Packages/BlipMesh/Sources/CrowdScaleManager.swift`
- Create: `Packages/BlipMesh/Sources/ClusterManager.swift`
- Create: `Packages/BlipMesh/Sources/TrafficShaper.swift`
- Create: `Packages/BlipMesh/Sources/PowerManager.swift`
- Create: `Packages/BlipMesh/Sources/ReputationManager.swift`
- Test: `Packages/BlipMesh/Tests/CrowdScaleTests.swift`

- [ ] **Step 1: Implement `CrowdScaleManager.swift`**

4 modes: Gather (<500), Festival (500-5K), Mega (5K-25K), Massive (25K-100K+). Detection via unique peer count (direct + announced neighbors, EMA smoothed, 60s hysteresis). Publishes current mode via Combine.

- [ ] **Step 2: Implement `ClusterManager.swift`**

RSSI-based proximity grouping. Target: 20-60 peers per cluster. Bridge node detection (connected to 2+ clusters). Cluster split at 80 peers.

- [ ] **Step 3: Implement `TrafficShaper.swift`**

4-lane priority queue (Critical/High/Normal/Low). Rate limiting: 20pps inbound, 15pps outbound, 2x burst for 3s. Backpressure: >80% stops relay, >95% drops Lane 3.

- [ ] **Step 4: Implement `PowerManager.swift`**

4 battery tiers: Performance (>60%), Balanced (30-60%), PowerSaver (10-30%), UltraLow (<10%). Controls scan duty cycle and advertise interval. Monitors `UIDevice.current.batteryLevel`.

- [ ] **Step 5: Implement `ReputationManager.swift`**

Block vote tallying per cluster. 10 votes → deprioritize. 25 votes → drop broadcasts. Reset per festival. SOS exempt.

- [ ] **Step 6: Run tests, commit**

```bash
git commit -m "feat(mesh): add crowd-scale modes, clustering, traffic shaping, power management, reputation"
```

### Task 4.4: Transport Coordinator & WebSocket Fallback

**Files:**
- Create: `Packages/BlipMesh/Sources/TransportCoordinator.swift`
- Create: `Packages/BlipMesh/Sources/WebSocketTransport.swift`
- Create: `Packages/BlipMesh/Sources/WiFiTransport.swift`

- [ ] **Step 1: Implement `TransportCoordinator.swift`**

Owns all transports. Routes messages: BLE first (100ms timeout) → WebSocket fallback → local queue. Automatic handoff. Publishes transport state via Combine.

- [ ] **Step 2: Implement `WebSocketTransport.swift`**

`URLSessionWebSocketTask` to `wss://relay.blip.app/ws`. Auth: Noise public key as bearer token. Binary frames with protocol packets. Reconnection: exponential backoff 1s-60s, max 10 attempts.

- [ ] **Step 3: Implement `WiFiTransport.swift`**

Stub/placeholder for v2. Conforms to `Transport` protocol. All methods return immediately or throw `.notImplemented`.

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(mesh): add transport coordinator, WebSocket fallback, WiFi stub"
```

---

## Phase 5: SwiftData Models

### Task 5.1: Core Data Models

**Files:**
- Create: `Sources/Models/User.swift`
- Create: `Sources/Models/Friend.swift`
- Create: `Sources/Models/Message.swift`
- Create: `Sources/Models/Attachment.swift`
- Create: `Sources/Models/Channel.swift`
- Create: `Sources/Models/GroupMembership.swift`
- Create: `Sources/Models/MeshPeer.swift`
- Create: `Sources/Models/MessageQueue.swift`

- [ ] **Step 1: Implement all core models**

SwiftData `@Model` classes matching spec Section 14.1 exactly. All relationships, enums, computed properties. Indexes on: `Message.createdAt`, `Message.channel+createdAt`, `Channel.lastActivityAt`, `MeshPeer.lastSeenAt`, `Friend.status`.

- [ ] **Step 2: Commit**

```bash
git commit -m "feat(models): add core SwiftData models — User, Friend, Message, Channel, etc"
```

### Task 5.2: Festival & Medical Models

**Files:**
- Create: `Sources/Models/Festival.swift`
- Create: `Sources/Models/Stage.swift`
- Create: `Sources/Models/SetTime.swift`
- Create: `Sources/Models/MeetingPoint.swift`
- Create: `Sources/Models/SOSAlert.swift`
- Create: `Sources/Models/MedicalResponder.swift`
- Create: `Sources/Models/FriendLocation.swift`
- Create: `Sources/Models/BreadcrumbPoint.swift`
- Create: `Sources/Models/CrowdPulse.swift`
- Create: `Sources/Models/UserPreferences.swift`
- Create: `Sources/Models/MessagePack.swift`
- Create: `Sources/Models/GroupSenderKey.swift`
- Create: `Sources/Models/NoiseSessionModel.swift`

- [ ] **Step 1: Implement all festival, medical, and support models**

All remaining SwiftData models from spec Section 14.1. Festival with `organizerSigningKey`. SOSAlert with `description` field. MessagePack with pack types. UserPreferences with all settings. GroupSenderKey with key material, counter, epoch.

- [ ] **Step 2: Commit**

```bash
git commit -m "feat(models): add festival, medical, location, preferences, and crypto models"
```

---

## Phase 6: Services Layer

### Task 6.1: Message Service & Retry

**Files:**
- Create: `Sources/Services/MessageService.swift`
- Create: `Sources/Services/MessageRetryService.swift`

- [ ] **Step 1: Implement `MessageService.swift`**

Orchestrates message send/receive. `send(content:to:type:)` → encrypt → serialize → hand to transport coordinator. `receive(data:from:)` → deserialize → decrypt → store in SwiftData → notify UI. Message balance check (deduct from pack). Routes to correct channel.

- [ ] **Step 2: Implement `MessageRetryService.swift`**

Monitors `MessageQueue`. Retry with exponential backoff. Max 50 attempts, 24-hour expiry. 500 message queue cap. Marks expired messages as failed.

- [ ] **Step 3: Commit**

```bash
git commit -m "feat(services): add message service and retry queue"
```

### Task 6.2: Location, Audio, Image, Notification Services

**Files:**
- Create: `Sources/Services/LocationService.swift`
- Create: `Sources/Services/AudioService.swift`
- Create: `Sources/Services/ImageService.swift`
- Create: `Sources/Services/NotificationService.swift`
- Create: `Sources/Services/PhoneVerificationService.swift`

- [ ] **Step 1: Implement `LocationService.swift`**

`CLLocationManager` wrapper. GPS for SOS (precise), friend sharing (configurable precision), geofence for festival detection. Geohash computation. 15-minute periodic checks.

- [ ] **Step 2: Implement `AudioService.swift`**

Opus codec encoding/decoding via swift-opus. Record voice notes (AVAudioRecorder), playback (AVAudioPlayer). PTT streaming: capture audio buffer → Opus encode → packet chunks.

- [ ] **Step 3: Implement `ImageService.swift`**

JPEG/HEIF compression. Thumbnail generation (64x64 for avatars, 200px for message previews). Image picker integration. LRU cache management (500MB cap).

- [ ] **Step 4: Implement `NotificationService.swift`**

Local notifications: new messages, friend nearby, set time alerts, SOS nearby assist. `UNUserNotificationCenter` wrapper.

- [ ] **Step 5: Implement `PhoneVerificationService.swift`**

SMS OTP flow. Send verification request to backend. Verify code. Store verified status.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(services): add location, audio, image, notification, phone verification services"
```

---

## Phase 7: ViewModels

### Task 7.1: Core ViewModels

**Files:**
- Create: `Sources/ViewModels/ChatViewModel.swift`
- Create: `Sources/ViewModels/MeshViewModel.swift`
- Create: `Sources/ViewModels/ProfileViewModel.swift`
- Create: `Sources/ViewModels/StoreViewModel.swift`
- Create: `Sources/ViewModels/LocationViewModel.swift`
- Create: `Sources/ViewModels/PTTViewModel.swift`
- Create: `Sources/ViewModels/FestivalViewModel.swift`
- Create: `Sources/ViewModels/SOSViewModel.swift`

- [ ] **Step 1: Implement `ChatViewModel.swift`**

`@MainActor @Observable`. Manages chat list, active conversation, message sending/receiving. Observes MessageService. Publishes sorted channel list, unread counts. Handles typing indicators.

- [ ] **Step 2: Implement `MeshViewModel.swift`**

Observes BLEService + PeerManager. Publishes: connected peer count, crowd scale mode, nearby friends, location channels.

- [ ] **Step 3: Implement `ProfileViewModel.swift`**

User profile CRUD. Avatar upload (camera/library → crop → compress → store). Friends list management. Block/unblock.

- [ ] **Step 4: Implement `StoreViewModel.swift`**

StoreKit 2 integration. Load products, purchase, verify receipts. Track message balance. Restore purchases.

- [ ] **Step 5: Implement `LocationViewModel.swift`**

Friend finder map state. Location sharing toggle per friend. "I'm here" beacon. Navigate to friend.

- [ ] **Step 6: Implement `PTTViewModel.swift`**

Push-to-talk state machine: idle → recording → sending. Audio capture → Opus encode → stream packets. Playback of received PTT.

- [ ] **Step 7: Implement `FestivalViewModel.swift`**

Festival discovery, manifest fetch, geofence. Stage map state, schedule, set time alerts. Crowd pulse aggregation.

- [ ] **Step 8: Implement `SOSViewModel.swift`**

SOS flow: severity selection → confirmation → GPS acquisition → broadcast. Medical dashboard for responders. False alarm tracking.

- [ ] **Step 9: Commit**

```bash
git commit -m "feat(viewmodels): add all view models — chat, mesh, profile, store, location, PTT, festival, SOS"
```

---

## Phase 8: UI — Core Navigation & Onboarding

### Task 8.1: App Entry & Tab Navigation

**Files:**
- Create: `App/AppDelegate.swift`
- Modify: `App/BlipApp.swift`
- Create: `Sources/Views/Tabs/MainTabView.swift`
- Create: `Sources/Views/Shared/ConnectionBanner.swift`
- Create: `Sources/Views/Shared/SOSButton.swift`

- [ ] **Step 1: Implement `AppDelegate.swift`**

BLE state restoration handlers. `willRestoreState` for central and peripheral managers.

- [ ] **Step 2: Update `BlipApp.swift`**

SwiftData model container with all models. Environment injection: theme, view models, services. Root view: onboarding if first launch, else MainTabView.

- [ ] **Step 3: Implement `MainTabView.swift`**

Custom floating glass tab bar. 4 tabs: Chats, Nearby, Festival (conditional), Profile. Accent glow on active tab. Cross-fade transitions. SOSButton overlay in top-right.

- [ ] **Step 4: Implement `ConnectionBanner.swift`**

Glass capsule: "Connected to X people nearby". Slides down on mesh connect, auto-dismisses after 3s.

- [ ] **Step 5: Implement `SOSButton.swift`**

Persistent floating pill. Subtle glass material. Red accent on press. Tap opens SOSConfirmationSheet.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(ui): add app entry, custom glass tab bar, connection banner, SOS button"
```

### Task 8.2: Onboarding Flow

**Files:**
- Create: `Sources/Views/Launch/SplashView.swift`
- Create: `Sources/Views/Launch/OnboardingFlow.swift`
- Create: `Sources/Views/Launch/WelcomeStep.swift`
- Create: `Sources/Views/Launch/CreateProfileStep.swift`
- Create: `Sources/Views/Launch/PermissionsStep.swift`

- [ ] **Step 1: Implement `SplashView.swift`**

Animated logo reveal with accent purple gradient. Fades to onboarding or main view.

- [ ] **Step 2: Implement `OnboardingFlow.swift`**

`TabView` with `.page` style. 3 steps. Progress dots. "Skip" hidden — all steps required.

- [ ] **Step 3: Implement `WelcomeStep.swift`**

"Chat at festivals, even without signal." Animated gradient hero. Continue button.

- [ ] **Step 4: Implement `CreateProfileStep.swift`**

Username field (real-time validation), phone number field + OTP verification inline, optional avatar picker. Single glass card layout.

- [ ] **Step 5: Implement `PermissionsStep.swift`**

"Blip needs Bluetooth to connect with people nearby." Single permission request. Friendly illustration. One-tap grant.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(ui): add onboarding flow — welcome, profile creation, permissions"
```

---

## Phase 9: UI — Chat System

### Task 9.1: Chat List

**Files:**
- Create: `Sources/Views/Tabs/ChatsTab/ChatListView.swift`
- Create: `Sources/Views/Tabs/ChatsTab/ChatListCell.swift`
- Create: `Sources/Views/Shared/AvatarView.swift`
- Create: `Sources/Views/Shared/StatusBadge.swift`

- [ ] **Step 1: Implement `AvatarView.swift`**

Circular avatar image with gradient ring border. Friend: accent gradient. Nearby: green pulse animation. Subscriber: accent ring. Configurable size. Fallback: initials on gradient.

- [ ] **Step 2: Implement `StatusBadge.swift`**

Delivery status: composing (typing dots), sent (single check), delivered (double check), read (double check filled). Subtle animation on state change.

- [ ] **Step 3: Implement `ChatListCell.swift`**

Glass card per conversation. Avatar, name, last message preview, timestamp, unread badge. Staggered reveal on appear. Swipe actions: pin, mute, archive.

- [ ] **Step 4: Implement `ChatListView.swift`**

`NavigationStack`. Search bar. Sorted by `lastActivityAt`. Pull-to-refresh with glass blur. FAB for new message. Empty state.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(ui): add chat list with glass cells, avatars, status badges"
```

### Task 9.2: Chat View (Message Thread)

**Files:**
- Create: `Sources/Views/Tabs/ChatsTab/ChatView.swift`
- Create: `Sources/Views/Tabs/ChatsTab/MessageBubble.swift`
- Create: `Sources/Views/Tabs/ChatsTab/MessageInput.swift`
- Create: `Sources/Views/Shared/TypingIndicator.swift`
- Create: `Sources/Views/Tabs/ChatsTab/VoiceNotePlayer.swift`
- Create: `Sources/Views/Tabs/ChatsTab/ImageViewer.swift`
- Create: `Sources/Views/Shared/PaywallSheet.swift`

- [ ] **Step 1: Implement `MessageBubble.swift`**

Glass bubble. Yours: right-aligned, accent-tinted glass. Theirs: left-aligned, neutral glass. Supports: text, voice note inline player, image thumbnail (tap to expand), reply quote. Long-press context menu (reply, copy, edit, delete, report). Spring animation on appear.

- [ ] **Step 2: Implement `TypingIndicator.swift`**

3 glass dots with sequential scale pulse. 0.4s duration, 0.15s offset between dots.

- [ ] **Step 3: Implement `MessageInput.swift`**

Text field with glass background. Left: attachment button (camera, photo, voice note). Right: morphing mic/send button (MorphingIcon). PTT hold button. Character counter for long messages.

- [ ] **Step 4: Implement `ChatView.swift`**

`ScrollViewReader` with `LazyVStack`. Auto-scroll to bottom on new message. Date section headers. Typing indicator at bottom. Message input pinned. Navigation title with avatar + online status.

- [ ] **Step 5: Implement `VoiceNotePlayer.swift`**

Inline waveform visualization. Play/pause button. Duration label. Playback speed toggle (1x/1.5x/2x).

- [ ] **Step 6: Implement `ImageViewer.swift`**

Full-screen image viewer. Pinch-to-zoom. Swipe down to dismiss. Share button.

- [ ] **Step 7: Implement `PaywallSheet.swift`**

Soft glass sheet from bottom. Message pack options. One-tap purchase via StoreKit 2. "Your message will send immediately after purchase."

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(ui): add chat view — message bubbles, input, typing indicator, media, paywall"
```

---

## Phase 10: UI — Nearby & Festival Tabs

### Task 10.1: Nearby Tab

**Files:**
- Create: `Sources/Views/Tabs/NearbyTab/NearbyView.swift`
- Create: `Sources/Views/Tabs/NearbyTab/NearbyPeerCard.swift`
- Create: `Sources/Views/Tabs/NearbyTab/LocationChannelList.swift`
- Create: `Sources/Views/Tabs/NearbyTab/FriendFinderMap.swift`
- Create: `Sources/Views/Tabs/NearbyTab/MeshParticleView.swift`

- [ ] **Step 1: Implement `MeshParticleView.swift`**

Ambient particle system. Dots represent mesh peers, gently floating. New peer: bloom/pulse. Connection lines between active relays (faint animated dash).

- [ ] **Step 2: Implement `NearbyPeerCard.swift`**

Glass card per nearby friend. Avatar, name, "X hops away", RSSI signal indicator.

- [ ] **Step 3: Implement `LocationChannelList.swift`**

Auto-discovered location channels. Channel name, member count, last message preview. Tap to join.

- [ ] **Step 4: Implement `FriendFinderMap.swift`**

MapKit view with friend dots. Colored pins per friend. Precision indicator (solid pin vs fuzzy circle). "I'm here" beacon drop. Navigate button. Breadcrumb trails (opt-in).

- [ ] **Step 5: Implement `NearbyView.swift`**

Combines: "X people nearby" header, mesh particle background, friends section, location channels section, friend finder map.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(ui): add nearby tab — mesh particles, peer cards, location channels, friend finder map"
```

### Task 10.2: Festival Tab

**Files:**
- Create: `Sources/Views/Tabs/FestivalTab/FestivalView.swift`
- Create: `Sources/Views/Tabs/FestivalTab/StageMapView.swift`
- Create: `Sources/Views/Tabs/FestivalTab/CrowdPulseOverlay.swift`
- Create: `Sources/Views/Tabs/FestivalTab/MeetingPointSheet.swift`
- Create: `Sources/Views/Tabs/FestivalTab/ScheduleView.swift`
- Create: `Sources/Views/Tabs/FestivalTab/SetTimeCell.swift`
- Create: `Sources/Views/Tabs/FestivalTab/AnnouncementFeed.swift`
- Create: `Sources/Views/Tabs/FestivalTab/LostAndFoundView.swift`

- [ ] **Step 1: Implement `StageMapView.swift`**

Interactive MapKit view with festival bounds. Stage hotspots (tappable → stage channel). Friend dots overlay. Meeting point pins. Pre-cached tiles for offline.

- [ ] **Step 2: Implement `CrowdPulseOverlay.swift`**

Heatmap overlay on stage map. Color-coded: quiet (blue) → moderate (green) → busy (orange) → packed (red). Computed from mesh peer density per geohash-7 cell.

- [ ] **Step 3: Implement `MeetingPointSheet.swift`**

Drop pin on map. Add label. Set expiry time. Share to group chat. Pin visible to selected friends/groups.

- [ ] **Step 4: Implement `ScheduleView.swift` + `SetTimeCell.swift`**

Scrollable schedule grouped by stage. Each cell: artist name, time, stage. Save button (star). Reminder toggle. "I'm going" share button.

- [ ] **Step 5: Implement `AnnouncementFeed.swift`**

Priority announcements from organizers. Glass cards with severity color coding. Emergency announcements pinned at top with red accent.

- [ ] **Step 6: Implement `LostAndFoundView.swift`**

Simple chat view for the lost & found channel. Pinned in festival tab.

- [ ] **Step 7: Implement `FestivalView.swift`**

Combines all above. Conditionally shown when at/joined a festival. Greyed out when out of geofence range.

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(ui): add festival tab — stage map, crowd pulse, schedule, announcements, lost & found"
```

---

## Phase 11: UI — Profile & Settings

### Task 11.1: Profile Tab

**Files:**
- Create: `Sources/Views/Tabs/ProfileTab/ProfileView.swift`
- Create: `Sources/Views/Tabs/ProfileTab/EditProfileView.swift`
- Create: `Sources/Views/Tabs/ProfileTab/AvatarCropView.swift`
- Create: `Sources/Views/Tabs/ProfileTab/FriendsListView.swift`
- Create: `Sources/Views/Tabs/ProfileTab/MessagePackStore.swift`
- Create: `Sources/Views/Tabs/ProfileTab/SettingsView.swift`
- Create: `Sources/Views/Shared/ProfileSheet.swift`

- [ ] **Step 1: Implement `ProfileView.swift`**

User avatar (large), display name, username, bio. Message pack balance. Quick actions: edit profile, friends, settings. Glass card layout.

- [ ] **Step 2: Implement `EditProfileView.swift`**

Edit: display name, username, bio, avatar. Phone re-verification. Avatar picker (camera/library).

- [ ] **Step 3: Implement `AvatarCropView.swift`**

Circular crop editor. Pinch-to-zoom, pan. Preview circle overlay. Confirm/cancel.

- [ ] **Step 4: Implement `FriendsListView.swift`**

Sections: Online, All Friends, Pending Requests, Blocked. Search. Add friend by username. Per-friend: location sharing toggle, nickname override.

- [ ] **Step 5: Implement `MessagePackStore.swift`**

StoreKit 2 product list. Pack cards with message count + price. Subscription option. Purchase flow. Balance display.

- [ ] **Step 6: Implement `SettingsView.swift`**

Theme (system/light/dark), location sharing default, notifications, PTT mode (hold/toggle), auto-join channels, crowd pulse visibility, account recovery export, about/legal.

- [ ] **Step 7: Implement `ProfileSheet.swift`**

Tap-any-avatar popup. Full avatar, name, username, bio, mutual friends. Actions: message, add friend, block, report.

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(ui): add profile tab — edit, avatar crop, friends list, message store, settings"
```

---

## Phase 12: UI — Medical/SOS System

### Task 12.1: SOS & Medical Dashboard

**Files:**
- Create: `Sources/Views/Shared/SOSConfirmationSheet.swift`
- Create: `Sources/Views/Tabs/FestivalTab/MedicalDashboard/MedicalDashboardView.swift`
- Create: `Sources/Views/Tabs/FestivalTab/MedicalDashboard/AlertCard.swift`
- Create: `Sources/Views/Tabs/FestivalTab/MedicalDashboard/ResponderMapView.swift`
- Create: `Sources/Views/Tabs/FestivalTab/MedicalDashboard/AlertDetailSheet.swift`

- [ ] **Step 1: Implement `SOSConfirmationSheet.swift`**

3 severity buttons: Green (tap confirm), Amber (slide to confirm), Red (hold 3s with haptic escalation + countdown circle). 10-second cancel banner after send. Proximity sensor check. False alarm throttle (drag captcha after 2+ false alarms).

- [ ] **Step 2: Implement `AlertCard.swift`**

Glass card per SOS alert. Severity color, elapsed time, location description. Accept/Navigate/Resolve buttons.

- [ ] **Step 3: Implement `ResponderMapView.swift`**

MapKit with SOS pins (pulsing red/amber/green). Medical tent locations. Responder locations. Walking route overlay. Accuracy indicator (solid vs pulsing vs dashed).

- [ ] **Step 4: Implement `AlertDetailSheet.swift`**

Full alert details. Live location streaming visualization. Accept/route/resolve workflow. Response timer.

- [ ] **Step 5: Implement `MedicalDashboardView.swift`**

Access code entry. Live map. Active alerts sorted severity-first. Response stats. Combines above components.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(ui): add SOS confirmation, medical dashboard, responder map, alert cards"
```

---

## Phase 13: Animations & Polish

### Task 13.1: Chat Animations & Waveform

**Files:**
- Create: `Sources/Animations/WaveformView.swift`
- Modify: `Sources/Views/Tabs/ChatsTab/MessageBubble.swift` (add spring entrance)
- Modify: `Sources/Views/Tabs/ChatsTab/MessageInput.swift` (add morphing icon)

- [ ] **Step 1: Implement `WaveformView.swift`**

Real-time audio amplitude visualization. Smooth bezier path driven by audio levels. Configurable color (accent purple for sending, muted for playback).

- [ ] **Step 2: Add spring entrance animations to MessageBubble**

Messages slide in from bottom-right (yours) or bottom-left (theirs) with spring physics.

- [ ] **Step 3: Wire up MorphingIcon in MessageInput**

Mic ↔ send arrow smooth shape interpolation based on text field content.

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(ui): add waveform visualizer, message spring animations, morphing send button"
```

---

## Phase 14: Documentation & Protocol Spec

### Task 14.1: Protocol Document & Whitepaper

**Files:**
- Create: `docs/PROTOCOL.md`
- Create: `docs/WHITEPAPER.md`

- [ ] **Step 1: Create `PROTOCOL.md`**

Cross-platform binary protocol specification extracted from design spec Section 6. This is the authoritative document for Android implementation.

- [ ] **Step 2: Create `WHITEPAPER.md`**

Blip whitepaper: problem statement, solution architecture, mesh networking approach, scalability, security model, festival integration. Public-facing document.

- [ ] **Step 3: Commit**

```bash
git commit -m "docs: add protocol specification and whitepaper"
```

---

## Phase 15: Integration & Testing

### Task 15.1: Integration Tests

**Files:**
- Create: `Tests/ProtocolTests/PacketRoundTripTests.swift`
- Create: `Tests/CryptoTests/NoiseIntegrationTests.swift`
- Create: `Tests/MeshTests/GossipRouterIntegrationTests.swift`
- Create: `Tests/ViewModelTests/ChatViewModelTests.swift`
- Create: `Tests/ViewModelTests/SOSViewModelTests.swift`

- [ ] **Step 1: Write protocol round-trip tests**

Create packet → serialize → deserialize → verify all fields match. Test all message types. Test fragmentation + reassembly round-trip. Test compression + padding round-trip.

- [ ] **Step 2: Write Noise integration tests**

Full handshake between two simulated peers. Encrypt message on one side, decrypt on other. Verify forward secrecy (compromise one session doesn't reveal others).

- [ ] **Step 3: Write gossip router integration tests**

Simulate 10-node mesh. Send message from node 1 → verify it reaches node 10 via gossip. Verify Bloom dedup prevents loops. Verify TTL decrements correctly.

- [ ] **Step 4: Write ViewModel tests**

ChatViewModel: send message, receive message, typing indicator, channel switching. SOSViewModel: SOS flow, cancel, false alarm throttle.

- [ ] **Step 5: Run all tests**

```bash
swift test --package-path Packages/BlipProtocol && \
swift test --package-path Packages/BlipCrypto && \
swift test --package-path Packages/BlipMesh
```

- [ ] **Step 6: Commit**

```bash
git commit -m "test: add integration tests for protocol, crypto, mesh, and view models"
```

---

## Execution Order Summary

| Phase | Description | Dependencies | Est. Files |
|---|---|---|---|
| 1 | Scaffold + Design System | None | ~25 |
| 2 | Protocol Package | None | ~15 |
| 3 | Crypto Package | Phase 2 | ~10 |
| 4 | Mesh Package | Phase 2, 3 | ~15 |
| 5 | SwiftData Models | None | ~20 |
| 6 | Services | Phase 2, 3, 4, 5 | ~7 |
| 7 | ViewModels | Phase 5, 6 | ~8 |
| 8 | UI: Navigation + Onboarding | Phase 1, 7 | ~10 |
| 9 | UI: Chat System | Phase 1, 7 | ~10 |
| 10 | UI: Nearby + Festival | Phase 1, 7 | ~15 |
| 11 | UI: Profile + Settings | Phase 1, 7 | ~8 |
| 12 | UI: Medical/SOS | Phase 1, 7 | ~5 |
| 13 | Animations + Polish | Phase 8-12 | ~3 |
| 14 | Documentation | Phase 2, 3, 4 | ~2 |
| 15 | Integration Tests | All | ~5 |

**Total: ~158 files across 15 phases**

**Parallelizable phases:** 1+2+5 can run in parallel. 3 depends on 2. 4 depends on 2+3. 6 depends on 2+3+4+5. 7+ depends on 5+6. 8-12 all depend on 1+7 but can run in parallel with each other.
