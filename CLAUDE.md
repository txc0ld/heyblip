# Blip — Claude Code Instructions

## Project Identity

Blip is a Bluetooth mesh chat app for events. iOS-first, SwiftUI, MVVM. The app lets users chat at events via BLE mesh when mobile reception is unavailable.

**Design spec:** `docs/superpowers/specs/2026-03-28-blip-design.md` — read this before any implementation work. It is the single source of truth.

## Build Configuration

- **Platform:** iOS 16.0+ / macOS 13.0+
- **Swift:** 5.9+
- **UI:** SwiftUI (no UIKit unless absolutely necessary)
- **Persistence:** SwiftData
- **Architecture:** MVVM
- **Package manager:** Swift Package Manager (SPM)
- **Build tool:** XcodeGen (`project.yml` generates `.xcodeproj`)

**Build command:**
```bash
xcodebuild -scheme Blip -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
```

**Test commands (per package — NOT xcodebuild test):**
```bash
swift test --package-path Packages/BlipProtocol
swift test --package-path Packages/BlipCrypto
swift test --package-path Packages/BlipMesh
```

Always use `-quiet` flag on xcodebuild to prevent context overflow from verbose build output.

## XcodeGen

The project uses XcodeGen — `project.yml` is the source of truth for the Xcode project, not the `.xcodeproj`.

**After adding, removing, or moving any source files:**
```bash
xcodegen generate
```

This regenerates the `.xcodeproj` from `project.yml`. If you add a new Swift file and the build fails with "no such module" or missing file errors, you probably forgot this step.

**Never modify `.pbxproj` directly** — always edit `project.yml` and regenerate.

## Critical Rules

### Never do these
- **NEVER modify `.pbxproj` files directly** — edit `project.yml` and run `xcodegen generate`
- **NEVER use force unwraps (`!`)** — use `guard let`, `if let`, or nil coalescing
- **NEVER use `var` when `let` suffices**
- **NEVER commit secrets, API keys, or credentials** — use environment variables or Keychain
- **NEVER add third-party UI libraries** — all UI is built with native SwiftUI
- **NEVER use UIKit views** unless wrapping a capability SwiftUI lacks (e.g., camera capture)
- **NEVER modify files outside the current task scope**
- **NEVER use bare `try?`** — always use `do/catch` with `DebugLogger` error logging

### Always do these
- **Read the design spec** before implementing any feature
- **Use `private` access control by default** — only widen to `internal`/`public` when needed
- **Add `#Preview` blocks** to every SwiftUI view
- **Handle all async errors explicitly** — use `do/catch` and log with `DebugLogger.shared.log("CATEGORY", "error description")`
- **Use `@MainActor`** for all ViewModels and UI-bound state
- **Validate at system boundaries** — all external data (BLE packets, network responses, user input)
- **Run tests after changes** — use the `swift test --package-path` commands above, not `xcodebuild test`
- **Run `xcodegen generate`** after adding or moving source files

## Project Structure

### SPM Packages

Three SPM packages under `Packages/`:

| Package | Responsibility |
|---|---|
| `BlipProtocol` | Binary packet format, serialization, Bloom filters, GCS sync, fragmentation |
| `BlipMesh` | BLE transport, peer discovery, gossip routing, WebSocket relay transport, congestion management |
| `BlipCrypto` | Noise XX handshake, Ed25519 signing, Keychain key management |

### App Source

App source is under `Sources/` with MVVM layout:
- `Sources/Views/` — SwiftUI views organized by tab (ChatsTab, NearbyTab, EventsTab, ProfileTab)
- `Sources/ViewModels/` — ObservableObject view models
- `Sources/Models/` — SwiftData model definitions
- `Sources/Services/` — Business logic services (messaging, audio, location, notifications)

### Backend (server/)

The `server/` directory contains Cloudflare Workers deployed to John's account:

| Worker | URL | Responsibility |
|---|---|---|
| `blip-auth` | `blip-auth.john-mckean.workers.dev` | User registration, login, key upload, user lookup |
| `blip-relay` | `blip-relay.john-mckean.workers.dev` | WebSocket relay for off-mesh message delivery |

Database: Neon Postgres (managed by Tay). Workers connect via `DATABASE_URL` environment variable in wrangler.toml.

**Server URLs are centralized in `Sources/Services/ServerConfig.swift`** — never hardcode server URLs anywhere else. If you need to reference auth or relay endpoints, import and use `ServerConfig`.

### Hot Files — Coordinate Before Editing

These files are touched by multiple features and PRs simultaneously. Before making changes, check if anyone else has an open PR touching the same file:

- **`Sources/Services/AppCoordinator.swift`** — app lifecycle, service initialization, key sync. Highest conflict risk.
- **`Sources/Services/MessageService.swift`** — message send/receive, friend requests, payload parsing
- **`Sources/Services/BLEService.swift`** — BLE peripheral/central management, connection state
- **`Sources/Models/` shared models** — any SwiftData model changes affect multiple views

If your task touches a hot file and you're rebasing against main, expect merge conflicts in these files. Resolve carefully — don't drop other people's changes.

## Auth & Registration Flow

The app uses email + social login (no phone/SMS). The flow:
1. User registers via `blip-auth` worker → server stores user record
2. App generates Noise XX keypair + Ed25519 signing key locally (Keychain)
3. App uploads public keys to server via `blip-auth/keys` endpoint
4. Other users look up public keys via `blip-auth/lookup?username=...`
5. DMs use Noise XX handshake for E2E encryption

**Critical:** Registration must upload keys to the server. If keys are `null` on the server, the "Add Friend" button will be disabled (by design — `noisePublicKey == nil` guard). If friend requests aren't working, check key upload first.

## Debug Logging

Use the shared `DebugLogger` for all logging — never use `print()` in production code:

```swift
DebugLogger.shared.log("BLE", "Discovered peer: \(peerID)")
DebugLogger.shared.log("AUTH", "Key upload failed: \(error)")
DebugLogger.shared.log("MESSAGE", "Sending DM to \(recipientUsername)")
```

Categories in use: `BLE`, `AUTH`, `MESSAGE`, `RELAY`, `GOSSIP`, `CRYPTO`, `SYNC`, `APP`.

The debug overlay (accessible in-app) displays these logs in real time — useful for on-device testing.

## Design Tokens

**Font:** Plus Jakarta Sans (Regular, Medium, SemiBold, Bold) — loaded from `Resources/Fonts/`

**Colors (use Asset Catalog named colors):**

| Token | Dark | Light |
|---|---|---|
| `Background` | `#000000` | `#FFFFFF` |
| `Text` | `#FFFFFF` | `#000000` |
| `MutedText` | `rgba(255,255,255,0.5)` | `rgba(0,0,0,0.5)` |
| `Border` | `rgba(255,255,255,0.08)` | `rgba(0,0,0,0.08)` |
| `CardBG` | `rgba(255,255,255,0.02)` | `rgba(0,0,0,0.02)` |
| `Hover` | `rgba(255,255,255,0.05)` | `rgba(0,0,0,0.05)` |
| `AccentPurple` | `#6600FF` | `#6600FF` |

**Glassmorphism:** Use `.ultraThinMaterial`, `.regularMaterial`, `.thickMaterial` for glass surfaces. Chat bubbles get translucent glass with 0.5pt white border at 20% opacity. Cards use `cornerRadius(24)`.

**Animations:** Spring animations (`stiffness: 300, damping: 24`), 50ms stagger for lists, `cubic-bezier(0.16, 1, 0.3, 1)` for reveals. Respect `UIAccessibility.isReduceMotionEnabled`.

## SwiftUI Standards

- **View files:** Max ~200 lines. Extract subviews when exceeding
- **State management:** `@State` for local, `@StateObject` / `@ObservedObject` for view models, `@Environment` for SwiftData model context
- **Lists:** Use `LazyVStack` inside `ScrollView` for chat messages (not `List`)
- **Navigation:** `NavigationStack` with typed navigation paths
- **Sheets:** Use `.sheet` and `.fullScreenCover` with detents where appropriate
- **Loading/error/empty states:** Handle all three for every async view
- **Accessibility:** All interactive elements need `.accessibilityLabel()`. Use semantic elements. Minimum 44pt tap targets.

## Protocol Implementation Notes

- **Byte order:** All multi-byte integers are big-endian (network byte order)
- **Packet header:** 16 bytes fixed (see spec Section 6.1)
- **Fragmentation threshold:** 416 bytes (worst case: addressed + signed)
- **Encryption:** Noise_XX_25519_ChaChaPoly_SHA256 via CryptoKit + swift-sodium for Ed25519
- **BLE Service UUID:** `FC000001-0000-1000-8000-00805F9B34FB`
- **BLE Characteristic UUID:** `FC000002-0000-1000-8000-00805F9B34FB`
- **WebSocket relay:** `WebSocketTransport` in BlipMesh handles off-mesh delivery via `blip-relay` worker. Messages route through the relay when BLE peers aren't directly reachable.

## Dependencies (3 only)

| Package | Purpose |
|---|---|
| CryptoKit (Apple, built-in) | Curve25519, ChaChaPoly, SHA256 |
| swift-sodium | Ed25519 signing |
| swift-opus | Voice note + PTT audio codec |

Do not add any other dependencies without explicit approval.

## Files to Skip

Do not read or modify:
- `*.pbxproj`
- `DerivedData/`
- `.build/`
- `build/`
- `*.xcuserdata`
- `.DS_Store`

## Git

- Conventional commits: `type(scope): description`
- Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`
- One logical change per commit
- Never commit with failing tests
- **Branch naming:** `type/BDEV-XXX-short-description` (matches Linear ticket)
- **Before merging:** Always rebase onto latest `main` and re-run build + tests
- **After merging:** Update the Linear ticket status to Done

## Execution Model

1. Understand the task and read relevant code
2. Plan the approach (check design spec if UI-related)
3. Implement with minimal blast radius
4. Verify: build with xcodebuild, test with `swift test --package-path`
5. Deliver only when verified — green build, passing tests

Do not ask clarifying questions when the answer is in the codebase or the design spec. Execute autonomously.
