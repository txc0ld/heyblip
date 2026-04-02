# Repo Recon

## Architecture Map

### Native app

- `App/`
  - app entry, root view, app lifecycle
- `Sources/Services`
  - coordinator, messaging, transport glue, location, notifications, auth sync
- `Sources/ViewModels`
  - tab/domain logic for chat, event, profile, SOS, mesh, store
- `Sources/Views`
  - SwiftUI tab surfaces and onboarding
- `Sources/Models`
  - SwiftData entities for users, friends, channels, messages, events, responders, packs

### Swift packages

- `Packages/BlipProtocol`
  - packet format, flags, serialization, fragmentation, compression, Bloom/GCS
- `Packages/BlipCrypto`
  - key management, Noise session primitives, signing, replay protection
- `Packages/BlipMesh`
  - BLE transport, gossip routing, relay, crowd-scale behavior

### Server surfaces

- `server/auth`
  - email verification, registration/sync, receipt-verification stub
- `server/relay`
  - relay worker with Vitest coverage

## Major User Flows Mapped In Code

### App bootstrap

`BlipApp` creates a global `AppCoordinator`, but before remediation the tab shell was not consistently consuming coordinator-owned dependencies.

### Chat flow

- `ChatListView`
- `ChatViewModel`
- `MessageService`
- `Channel` / `Message` / `GroupMembership`

Before remediation, `ChatListView` could instantiate a private `MessageService` + `ChatViewModel`, bypassing the coordinator-wired transport stack.

### Event flow

- `EventView`
- `EventViewModel`
- `LocationService`
- `Event`, `Stage`, `SetTime`, `CrowdPulse`

Before remediation, the tab remained partly sample-data driven and could present event UI as live even when no active event state existed.

### Profile/settings/store flow

- `ProfileView`
- `SettingsView`
- `ProfileViewModel`
- `StoreViewModel`
- `VerifiedProfileSheet`

Before remediation, settings mixed `AppStorage` defaults with SwiftData preferences, sign-out did not actually tear down identity/local store, and multiple account/export/verification affordances were placeholders presented like live features.

## Implementation Hotspots

### `Sources/Services/AppCoordinator.swift`

Real runtime boundary for identity, BLE transport, relay, and feature startup. This is the highest-leverage surface in the app because dependency drift here propagates to every tab.

### `Sources/Services/MessageService.swift`

Core send/receive path for text, media, friend requests, presence, delivery acks, and persistence. The service signs packets, but private-message confidentiality is not fully wired through real Noise encryption yet.

### `Sources/ViewModels/ChatViewModel.swift`

State source for channels, unread counts, active thread, typing state, and DM creation. This layer was a direct casualty of composition drift.

### `server/auth/src/index.ts`

Trust boundary for registration/sync/receipt flows. It previously accepted client-controlled privileged fields and shipped with dev bypass enabled in configuration.

## Recon Findings

### 1. Composition root drift

The app had a coordinator, but the tabs were not consistently treating it as the source of truth. That produced:

- chat state split across multiple services
- profile/settings surfaces reading stale/default state
- event-mode UI presenting itself as live without real activation

### 2. Sample/demo drift in shipped UI

Several surfaces looked implemented while still relying on:

- fallback sample content
- static counters
- unsupported buttons
- unbacked purchase/verification narratives

### 3. Trust boundary mismatch

The repo included strong crypto packages and signing tests, but app integration remained incomplete:

- signed packets are real
- packet type names and docs still imply confidentiality that the current app does not fully provide
- receipt verification and verified-profile purchase UX overstated readiness

### 4. Verification surface quality

Strengths:

- good package/test coverage footprint
- native test target exercises protocol, crypto, routing, schema, and view models
- auth and relay workers have Vitest suites

Weaknesses:

- some package failures are already present on `main`
- Swift concurrency warnings remain broad
- real-device BLE validation is still not encoded in automated verification

## Risk Zones

| Zone | Why it matters |
|---|---|
| App composition | Single root cause for chat/profile/event drift |
| MessageService trust semantics | Direct user trust and docs alignment issue |
| Server auth worker | Privilege escalation / unsafe dev posture risk |
| Event activation | High-visibility feature can silently degrade into demo state |
| Sign-out / reset path | Identity and local state persistence can drift or leak |

## Source-Level Observations

- The repo is deeper and more real than a prototype skim suggests; package infrastructure is substantial.
- The highest-impact defects are not missing files. They are mismatches between existing layers that are only partially integrated.
- The repo already had enough architecture to support stronger behavior; the remediation opportunity was to reconnect and constrain it, not rewrite it.
