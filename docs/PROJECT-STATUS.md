# HeyBlip — Project Status

**Last updated:** 2026-04-14
**Branch:** `main`

---

## Completed Work

### Sprint 1 (John) — Merged

| PR | Branch | What |
|----|--------|------|
| #2 | `john/J2-gossip-routing-test` | 10 multi-hop gossip routing tests (444 LOC) |
| #1 | `john/J1-ble-mesh-testing` | BLE integration test harness (806 LOC), protocol abstractions for testability |
| #4 | `john/J4-websocket-relay` | Zero-knowledge WebSocket relay server (Cloudflare Workers), 24 tests |

### Sprint 2 (Tay) — Merged

| PR | Branch | What |
|----|--------|------|
| #7 | `tay/sprint2-frontend-wiring` | FEZ-28: ChatListView/ChatView wired to ChatViewModel |
| | | FEZ-29: NearbyView wired to MeshViewModel |
| | | FEZ-30: Onboarding generates Noise identity, creates User in SwiftData |

### Sprint 2 (John) — Merged

| PR | Branch | What |
|----|--------|------|
| #6 | `john/sprint2-service-init` | AppCoordinator (BLE + relay + identity + MessageService wiring) |
| | | Removed PhoneVerificationService (phone auth dropped) |
| | | Replaced bare `try?` with explicit error handling across all ViewModels |
| | | TransportCoordinator routes MessageService through BLE/WebSocket |

### Build Fixes — Merged

| PR | Branch | What |
|----|--------|------|
| #5 | `fix/build-errors-shapestyle-spring` | 19-file fix: deprecated APIs, actor isolation, type inference, iOS 17 target |

---

## What Works

### Infrastructure (95%)
- **Noise_XX_25519_ChaChaPoly_SHA256** — Full handshake, session caching, rekey, replay protection
- **Ed25519 signing** — Packet signing per spec 7.3
- **KeyManager** — Generate, store, load, recover identity from Keychain
- **Binary protocol** — 16-byte header, packet serialization, fragmentation/reassembly, compression, padding
- **Bloom filter** — Multi-tier dedup (hot 60s / warm 5min / cold 30min)
- **GCS sync** — Golomb-Coded Set exchange between peers
- **Push notifications** — APNs via auth worker, relay `triggerPush`, iOS `PushTokenManager`

### Mesh Networking (90%)
- **BLE transport** — Dual-role (central + peripheral), scan cycling, connection limits, state restoration
- **WebSocket relay** — JWT auth, store-and-forward with per-peer drain serialization, sender PeerID verification, broadcast fan-out, rate limiting, max 512B packets
- **TransportCoordinator** — BLE-first with 100ms timeout, WebSocket fallback, local queue (200 msgs)
- **Gossip routing** — TTL decrement, adaptive relay probability, SOS bypass, store-and-forward cache
- **Directed routing** — Announcement-based routing table for Mega/Massive modes
- **Congestion control** — Traffic shaper, priority queues (SOS > Normal > Background), per-peer rate limits
- **Crowd scale** — Auto-detection: Gather (<500) / Event (5K) / Mega (25K) / Massive (25K+)
- **Power management** — Battery-tier scan interval adjustment
- **Peer management** — RSSI-based connection selection, role-based limits, 20% hysteresis swaps

### App Layer (80%)
- **SwiftData models** — All 21 models complete with relationships and schema registration
- **AppCoordinator** — Initializes identity, BLE, relay, MessageService on launch
- **MessageService** — Send text/voice/image, E2E encrypted DMs (Noise XX), group messages (AES-256-GCM sender keys), typing indicators, delivery acks, read receipts, fragmentation, transport indicator (mesh/relay)
- **AudioService** — Voice note recording (30s max), Opus codec (24kbps voice / 16kbps PTT), playback
- **LocationService** — GPS with geofencing (15 regions), fuzzy vs precise sharing
- **NotificationService** — Local notifications for messages, SOS, friend requests, set time reminders
- **Registration failure feedback** — Error dialog plus persistent retry banner
- **EventsViewModel** — CDN refresh, dynamic announcement severity, 24h lost-and-found retention

### UI (85% built, ~80% wired)
- **Design system** — Glassmorphism, Plus Jakarta Sans, spring animations, dark/light theming
- **Onboarding** — 3-step flow: Welcome → Profile (identity gen) → Permissions
- **Chat** — ChatListView + ChatView wired to ChatViewModel; MessageBubble, VoiceNotePlayer, ImageViewer
- **Nearby** — NearbyView wired to MeshViewModel; peer cards, particle background, friend finder map
- **Event** — StageMap, Schedule, Announcements, LostAndFound, MeetingPoint, MedicalDashboard (UI complete, production data wired where available)
- **Profile** — ProfileView, EditProfile, FriendsList, AvatarCrop, MessagePackStore, Settings (UI complete, sample data)

### Relay Server (100%)
- Cloudflare Workers Durable Object
- JWT validation with authenticated WebSocket sessions
- Store-and-forward delivery with per-peer drain serialization
- Push trigger integration for offline recipients
- Broadcast fan-out and sender PeerID verification

---

## What's Left

### High Priority — Core App Loop

| Area | Task | Notes |
|------|------|-------|
| **Profile tab data binding** | ProfileView, FriendsListView, SettingsView use sample data | ProfileViewModel exists |
| **Friend system wiring** | Friend discovery, add/accept flow, location sharing toggle | Models and basic ViewModel exist |

### Medium Priority — Features

| Area | Task | Notes |
|------|------|-------|
| **SOS responder assignment** | Connect SOSViewModel broadcast → mesh → responder accept | Models, UI, and state machine defined; broadcast uses Identity correctly |
| **PTT streaming** | Live push-to-talk audio over mesh | PTTViewModel has recording state; chunked streaming partially done |
| **Image pipeline** | Compression, thumbnail generation, progressive loading | ImageService is basic; needs HEIF/JPEG quality ladder |

### Lower Priority — Polish

| Area | Task | Notes |
|------|------|-------|
| **Premium features** | Define and ship StoreKit 2 premium offering | Product scope still TBD |
| **Settings persistence** | Wire SettingsView toggles to UserPreferences SwiftData model | Model complete, view is stub |
| **Account recovery** | RecoveryKit export/import flow in settings | KeyManager supports it; no UI yet |
| **Lost & Found** | Item posting/searching in LostAndFoundView | View is stub |
| **Content moderation** | Report/block mechanism | Not started |
| **WiFi Direct transport** | `WiFiTransport.swift` returns `.notImplemented` | Planned for v2 |
| **Performance** | Bloom filter false positive tuning, scan interval optimization | Infrastructure ready |
| **Integration tests** | Full message flow: send → encrypt → mesh → receive → decrypt → display | Individual unit tests pass; no end-to-end test |

---

## Test Counts

| Suite | Tests | Status |
|-------|-------|--------|
| BlipMesh (Swift) | 115 | Passing |
| BlipProtocol (Swift) | ~40 | Passing |
| BlipCrypto (Swift) | ~25 | Passing |
| SwiftData schema validation | ~50 | Passing |
| server/relay (Vitest) | Expanded coverage for JWT validation, push trigger, drain serialization, and fan-out | Passing |
| **Total** | **Core suites green** | **All green** |

---

## Architecture

```
┌─────────────────────────────────────────────┐
│                   Views                      │
│  ChatsTab · NearbyTab · EventsTab · Profile│
├─────────────────────────────────────────────┤
│                ViewModels                    │
│  Chat · Mesh · Event · SOS · Location     │
├─────────────────────────────────────────────┤
│              AppCoordinator                  │
│  Identity · Services · Transport lifecycle   │
├──────────┬──────────┬───────────────────────┤
│ Message  │ Location │ Audio · Image · Notif  │
│ Service  │ Service  │ Service   Service       │
├──────────┴──────────┴───────────────────────┤
│           TransportCoordinator               │
│        BLE-first → WebSocket fallback        │
├──────────────┬──────────────────────────────┤
│ Blip    │ BlipMesh                 │
│ Protocol     │ BLE · WebSocket · Gossip      │
│ Packets/TLV  │ PeerMgr · CrowdScale         │
├──────────────┴──────────────────────────────┤
│           BlipCrypto                    │
│  Noise XX · Ed25519 · KeyManager · Sessions  │
└─────────────────────────────────────────────┘
```

---

## Build

```bash
# App (iOS 17+)
xcodebuild -scheme Blip -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGN_IDENTITY="" CODE_SIGNING_ALLOWED=NO -quiet

# Mesh package tests
swift test --package-path Packages/BlipMesh

# Relay server tests
cd server/relay && npm install && npx vitest run
```

**Current status:** All builds pass. All tests green.
