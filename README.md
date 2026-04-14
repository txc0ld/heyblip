<p align="center">
  <img src="https://img.shields.io/badge/Platform-iOS%2017%2B%20%7C%20macOS%2013%2B-6600FF?style=for-the-badge&logo=apple&logoColor=white" alt="Platform">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/License-Proprietary-333333?style=for-the-badge" alt="License">
  <img src="https://img.shields.io/badge/Status-In%20Development-6600FF?style=for-the-badge" alt="Status">
</p>

<h1 align="center">
  HeyBlip
</h1>

<p align="center">
  <strong>Chat at events, even without signal.</strong>
</p>

<p align="center">
  A Bluetooth mesh chat app that turns every phone at a event into a communication node.<br>
  No towers. No WiFi. No problem.
</p>

---

## The Problem

At large events (10,000 - 100,000+ attendees), mobile networks collapse. Towers get overwhelmed, texts fail, and finding your friends becomes a shouting match in a crowd of strangers. Emergency services can't reach you. You're disconnected at the one place you came to connect.

## The Solution

HeyBlip creates a **self-forming mesh network** using Bluetooth Low Energy. Every phone running the app becomes a relay node. Messages hop from device to device across the crowd until they reach their destination — no cell towers, no WiFi, no internet required.

When signal is available, HeyBlip seamlessly falls back to WiFi and cellular. But the mesh is always the first choice.

---

## Features

### Mesh Chat
- **1-on-1 DMs** — End-to-end encrypted with Noise_XX_25519_ChaChaPoly_SHA256
- **Group chats** — AES-256-GCM sender key encryption with automatic key rotation
- **Location channels** — Auto-joined public channels based on where you are
- **Stage channels** — Event-specific channels per stage, auto-populated

### Walkie-Talkie
- **Push-to-talk** — Hold to talk, release to send, just like a radio
- **Voice notes** — Short compressed audio when real-time isn't possible
- **Graceful degradation** — Real-time on mesh, voice note on internet, queued offline

### Find Your Friends
- **GPS friend finder** — See friends on the event map (privacy controls per friend)
- **Proximity alerts** — "Jake is nearby!" when a friend enters Bluetooth range
- **"I'm here" beacons** — Drop a pin and share your location with your group
- **Meeting points** — Set a pin on the map with a label and expiry time

### Event Integration
- **Stage map** — Interactive map with crowd density heatmap
- **Schedule** — Lineup with set time alerts ("Bicep starts in 15 min!")
- **Announcements** — Priority broadcasts from event organizers
- **Lost & Found** — Dedicated channel per event
- **Auto-discovery** — App detects which event you're at via GPS

### Medical SOS
- **One-tap emergency** — 3 severity tiers (Green / Amber / Red)
- **GPS precision** — Precise coordinates sent to medical responders
- **Medical dashboard** — Responders see live map with SOS pins and walking directions
- **Guaranteed delivery** — SOS packets override ALL congestion rules at any crowd scale
- **False alarm safeguards** — Tiered confirmation prevents accidental activation

### Scales to 100,000+
- **4 crowd-scale modes** — Automatically adapts from 50 people to 100K+
- **Smart congestion** — Text stays reliable at any scale, media offloads to internet when needed
- **Cluster topology** — Self-organizing mesh segments with bridge nodes
- **Battery aware** — 4 power tiers keep your phone alive all day

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│               HeyBlip App                  │
│                                                  │
│   SwiftUI Views (Glassmorphism + Animations)     │
│              ┌─────────────┐                     │
│              │  ViewModels  │  @Observable MVVM   │
│              └──────┬──────┘                     │
│     ┌───────────────┼───────────────┐            │
│     │               │               │            │
│  ┌──▼──┐     ┌──────▼──────┐  ┌────▼────┐      │
│  │Crypto│     │  Protocol   │  │SwiftData│      │
│  │      │     │             │  │         │      │
│  │Noise │     │ Packets     │  │21 Models│      │
│  │XX    │     │ Bloom/GCS   │  │         │      │
│  │Ed25519│    │ Fragments   │  │         │      │
│  └──┬───┘     └──────┬──────┘  └─────────┘      │
│     │               │                            │
│  ┌──▼───────────────▼──────────────────────┐    │
│  │          Mesh Transport Layer            │    │
│  │  BLE (primary) │ WebSocket │ WiFi (v2)  │    │
│  └─────────────────────────────────────────┘    │
└──────────────────────────────────────────────────┘
```

### Three SPM Packages

| Package | Responsibility |
|---|---|
| **BlipProtocol** | Binary packet format (16-byte header), serialization, 3-tier Bloom filters, GCS sync, fragmentation, TLV encoding, zlib compression, PKCS#7 padding |
| **BlipCrypto** | Noise XX handshake (Curve25519/ChaChaPoly/SHA256), Ed25519 signing, iOS Keychain management, replay protection, AES-256-GCM sender keys for groups |
| **BlipMesh** | BLE dual-role transport, gossip routing, store-and-forward, adaptive relay probability, directed routing, 4 crowd-scale modes, RSSI clustering, 4-lane traffic shaping, battery-aware power management, WebSocket fallback |

---

## Security

End-to-end encryption is live for DMs and group chats, and relay nodes cannot read private-message payloads.

| Layer | Implementation |
|---|---|
| **Key Exchange** | Noise_XX_25519_ChaChaPoly_SHA256 |
| **Signing** | Ed25519 (packet authenticity) |
| **Group Encryption** | AES-256-GCM sender keys with automatic key rotation |
| **Key Storage** | iOS Keychain (`kSecAttrAccessibleAfterFirstUnlock`) |
| **Replay Protection** | Sliding window nonce (64-bit counter + 128-bit bitmap) |
| **Traffic Analysis** | PKCS#7 padding to fixed block sizes |
| **Phone Privacy** | SHA256(phone + per-user salt), never transmitted raw |

No tracking. Keys are generated on your device and signing keys stay local.

---

## Tech Stack

| Component | Technology |
|---|---|
| Language | Swift 5.9+ |
| UI | SwiftUI + Glassmorphism |
| Persistence | SwiftData |
| Networking | CoreBluetooth (BLE mesh) |
| Crypto | CryptoKit + libsodium (swift-sodium) |
| Audio | AVFoundation + Opus (swift-opus) |
| Maps | MapKit |
| Payments | StoreKit 2 |
| Build | XcodeGen + Swift Package Manager |
| Font | Plus Jakarta Sans |
| Accent | `#6600FF` |

---

## Design Language

HeyBlip uses a **glassmorphism** design system with translucent materials, depth, and bold gradients.

- **Materials**: `.ultraThinMaterial`, `.regularMaterial`, `.thickMaterial`
- **Cards**: Glass containers with `cornerRadius(24)` and 0.5pt borders at 20% opacity
- **Animations**: Spring physics (`stiffness: 300, damping: 24`), staggered reveals, scroll reveals
- **Accessibility**: Full VoiceOver, Dynamic Type, Reduce Motion support, 44pt minimum tap targets

### Color Tokens

| Token | Dark | Light |
|---|---|---|
| Background | `#000000` | `#FFFFFF` |
| Text | `#FFFFFF` | `#000000` |
| Muted | `rgba(255,255,255,0.5)` | `rgba(0,0,0,0.5)` |
| Accent | `#6600FF` | `#6600FF` |

---

## Project Structure

```
Blip/
├── App/                          # Entry point, Info.plist, entitlements
├── Sources/
│   ├── DesignSystem/             # Colors, typography, spacing, glass components
│   ├── Animations/               # Spring, stagger, scroll, ripple, waveform, morph
│   ├── Models/                   # 21 SwiftData models
│   ├── Services/                 # Messaging, audio, image, location, notifications
│   ├── ViewModels/               # 8 @Observable view models
│   └── Views/
│       ├── Launch/               # Splash, onboarding (3 screens)
│       ├── Shared/               # Avatar, glass card, SOS button, premium UI
│       └── Tabs/
│           ├── ChatsTab/         # Chat list, message thread, voice notes
│           ├── NearbyTab/        # Peer cards, channels, friend finder map
│           ├── EventsTab/      # Stage map, schedule, announcements, medical
│           └── ProfileTab/       # Profile, friends, settings, premium features
├── Packages/
│   ├── BlipProtocol/        # Binary wire format + tests
│   ├── BlipCrypto/          # E2E encryption + tests
│   └── BlipMesh/            # BLE mesh networking + tests
├── Tests/                        # Integration tests
├── Resources/Fonts/              # Plus Jakarta Sans (4 weights)
└── docs/
    ├── PROTOCOL.md               # Cross-platform binary spec
    ├── WHITEPAPER.md             # Project whitepaper
    └── superpowers/specs/        # Design specification
```

---

## Binary Protocol

Blip uses a compact binary protocol designed for BLE's ~512-byte MTU. The protocol spec is the cross-platform contract — any implementation (Swift, Kotlin, or future) that correctly produces these bytes is compatible.

```
┌──────────────────────────────────────────────────────┐
│ Version │ Type │ TTL │ Timestamp (8B) │ Flags │ Len  │
│  1 byte │  1B  │ 1B  │    UInt64     │  1B   │  4B  │
├──────────────────────────────────────────────────────┤
│ Sender ID (8B) │ [Recipient ID (8B)] │ Payload │ Sig │
└──────────────────────────────────────────────────────┘
                    16-byte header
              Big-endian byte order
```

Full specification: [`docs/PROTOCOL.md`](docs/PROTOCOL.md)

---

## Crowd-Scale Modes

| Mode | Peers | Mesh Features | Media |
|---|---|---|---|
| **Gather** | < 500 | Full features | All media types |
| **Event** | 500 - 5K | Moderate throttle | Text + compressed voice |
| **Mega** | 5K - 25K | Text-first | Text only on mesh |
| **Massive** | 25K - 100K+ | Aggressive clustering | Text only, media via internet |

SOS alerts are **never throttled** at any scale. TTL 7, 100% relay, queue-jumping, dual-path delivery.

---

## Monetization

Messages are free at all crowd scales. Premium features (TBD) will be offered via StoreKit 2.

---

## Platforms

| Platform | Status | Details |
|---|---|---|
| **iOS** | In Development | iOS 17.0+, Swift/SwiftUI, Xcode |
| **macOS** | In Development | macOS 13.0+, same codebase |
| **Android** | Planned | API 26+, Kotlin, same binary protocol |

---

## Building

```bash
# Prerequisites
brew install xcodegen

# Generate Xcode project
xcodegen generate

# Open in Xcode
open Blip.xcodeproj

# Build
xcodebuild -scheme Blip -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
```

---

## Documentation

| Document | Description |
|---|---|
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md) | Cross-platform binary protocol specification |
| [`docs/WHITEPAPER.md`](docs/WHITEPAPER.md) | Project whitepaper |
| [`docs/superpowers/specs/blip-design.md`](docs/superpowers/specs/blip-design.md) | Full design specification (1,500+ lines) |
| [`docs/superpowers/plans/2026-03-28-blip-implementation.md`](docs/superpowers/plans/2026-03-28-blip-implementation.md) | Implementation plan |

---

## Test Suite

```bash
# Protocol tests (144 tests)
swift test --package-path Packages/BlipProtocol

# Crypto tests (41 tests + 5 Keychain tests on device)
swift test --package-path Packages/BlipCrypto

# Mesh tests (68 tests)
swift test --package-path Packages/BlipMesh
```

253+ test cases covering packet serialization, Noise handshakes, gossip routing, congestion management, and ViewModel logic.

---

## Contributing

HeyBlip is currently in private development. If you're interested in contributing to the Android implementation or the mesh protocol, reach out.

---

<p align="center">
  <strong>Built for events. Powered by the crowd.</strong>
</p>
