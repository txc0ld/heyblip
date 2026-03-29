# Blip — Claude Cowork / Xcode Instructions

## Project Identity

Blip is a Bluetooth mesh chat app for festivals. iOS-first, SwiftUI, MVVM. The app lets users chat at festivals via BLE mesh when mobile reception is unavailable.

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
xcodebuild -scheme Blip -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -quiet
```

**Test command:**
```bash
xcodebuild test -scheme Blip -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -quiet
```

Always use `-quiet` flag to prevent context overflow from verbose build output.

## Critical Rules

### Never do these
- **NEVER modify `.pbxproj` files directly** — create source files, I will add them to Xcode manually, or regenerate via XcodeGen
- **NEVER use force unwraps (`!`)** — use `guard let`, `if let`, or nil coalescing
- **NEVER use `var` when `let` suffices**
- **NEVER commit secrets, API keys, or credentials** — use environment variables or Keychain
- **NEVER add third-party UI libraries** — all UI is built with native SwiftUI
- **NEVER use UIKit views** unless wrapping a capability SwiftUI lacks (e.g., camera capture)
- **NEVER modify files outside the current task scope**

### Always do these
- **Read the design spec** before implementing any feature
- **Use `private` access control by default** — only widen to `internal`/`public` when needed
- **Add `#Preview` blocks** to every SwiftUI view
- **Handle all async errors explicitly** — no swallowed errors, no bare `try?`
- **Use `@MainActor`** for all ViewModels and UI-bound state
- **Validate at system boundaries** — all external data (BLE packets, network responses, user input)
- **Run tests after changes** — verify before claiming completion

## Project Structure

Three SPM packages under `Packages/`:

| Package | Responsibility |
|---|---|
| `BlipProtocol` | Binary packet format, serialization, Bloom filters, GCS sync, fragmentation |
| `BlipMesh` | BLE transport, peer discovery, gossip routing, congestion management |
| `BlipCrypto` | Noise XX handshake, Ed25519 signing, Keychain key management |

App source is under `Sources/` with MVVM layout:
- `Sources/Views/` — SwiftUI views organized by tab (ChatsTab, NearbyTab, FestivalTab, ProfileTab)
- `Sources/ViewModels/` — ObservableObject view models
- `Sources/Models/` — SwiftData model definitions
- `Sources/Services/` — Business logic services (messaging, audio, location, notifications)

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

## Execution Model

Follow the AGENTS.md execution contract in the repo root:
1. Understand the task and read relevant code
2. Plan the approach (check design spec)
3. Implement with minimal blast radius
4. Verify with build + tests
5. Deliver only when verified

Do not ask clarifying questions when the answer is in the codebase or the design spec. Execute autonomously.
