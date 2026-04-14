# Blip — Claude Code Instructions

## Project Identity

Blip is a Bluetooth mesh chat app for events. iOS-first, SwiftUI, MVVM. The app lets users chat at events (festivals, sporting events, ultra marathons, concerts, any high-density gathering) via BLE mesh when mobile reception is unavailable.

**Design spec:** `docs/superpowers/specs/blip-design.md` — read this before any implementation work. It is the single source of truth.

## Build Configuration

- **Platform:** iOS 17.0+ / macOS 13.0+
- **Swift:** 5.9+
- **UI:** SwiftUI (no UIKit unless absolutely necessary)
- **Persistence:** SwiftData
- **Architecture:** MVVM
- **Package manager:** Swift Package Manager (SPM)
- **Build tool:** XcodeGen (`project.yml` generates `.xcodeproj`)

**Build command:**
```bash
xcodebuild -scheme Blip -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGN_IDENTITY="" CODE_SIGNING_ALLOWED=NO -quiet
```

> **Why the signing flags?** `project.yml` sets `DEVELOPMENT_TEAM` for distribution builds. Without these overrides, `xcodebuild` prompts for an Apple ID — breaking CI and anyone without the team's developer account. Simulator builds don't need signing.

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
- `Sources/Views/` — SwiftUI views: `Launch/`, `Shared/`, and `Tabs/{ChatsTab,EventsTab,NearbyTab,ProfileTab}`
- `Sources/ViewModels/` — ObservableObject view models
- `Sources/Models/` — SwiftData model definitions
- `Sources/Services/` — Business logic services (messaging, audio, location, notifications, auth tokens, crash reporting, sync)
- `Sources/Animations/` — Reusable SwiftUI animation components (springs, particles, waveforms, stagger reveals)
- `Sources/DesignSystem/` — Design tokens in code: colors, typography, spacing, glass components, shimmer/haptic modifiers
- `Sources/Utilities/` — Build info helpers

### Backend (server/)

The `server/` directory contains Cloudflare Workers deployed to John's account:

| Worker | URL | Responsibility |
|---|---|---|
| `blip-auth` | `blip-auth.john-mckean.workers.dev` | Ed25519 challenge-response registration, email verification (Resend), JWT session tokens (`/v1/auth/token`, `/v1/auth/refresh`), key upload, user lookup |
| `blip-relay` | `blip-relay.john-mckean.workers.dev` | WebSocket relay with store-and-forward (Durable Object storage, 50 packets/peer cap, 1hr TTL), broadcast fan-out for non-addressed packets, sender PeerID verification, per-peer drain serialization with retry (3 attempts, 5s×N backoff), failed-key tracking, JWT validation (accepts JWT or legacy base64 key, expired JWT → close 4001), alarm-based cleanup |
| `blip-cdn` | `blip-cdn.john-mckean.workers.dev` | Static event manifests, public assets, and avatar storage. `/manifests/events.json` serves seed events. `POST /avatars/upload` (JWT-authed) stores JPEG avatars in R2 bucket `blip-avatars`, returns CDN URL. `GET /avatars/:id.jpg` serves avatars via R2. CORS enabled (`*`), 1hr cache on manifests. Source in `server/cdn/`. |

The `server/` directory also contains a `verify/` stub (currently unused).

Database: Neon Postgres (managed by Tay). `blip-auth` and `blip-relay` connect via `DATABASE_URL` environment variable in wrangler.toml. `blip-cdn` uses R2 (no DB) — bucket `blip-avatars` + `JWT_SECRET` shared with `blip-auth`.

**Server URLs are centralized in `Sources/Services/ServerConfig.swift`** — never hardcode server URLs anywhere else. If you need to reference auth or relay endpoints, import and use `ServerConfig`.

### Hot Files — Coordinate Before Editing

These files are touched by multiple features and PRs simultaneously. Before making changes, check if anyone else has an open PR touching the same file:

- **`Sources/Services/AppCoordinator.swift`** — app lifecycle, service initialization, key sync. Highest conflict risk.
- **`Sources/Services/MessageService.swift`** — core message send/receive, encryption routing, relay transport (~1,490 lines after decomposition). Extensions in `MessageService+FriendRequests.swift` and `MessageService+Handshake.swift`. Still a hot file but conflict risk is reduced.
- **`Sources/Services/BLEService.swift`** — BLE peripheral/central management, connection state
- **`Sources/Models/` shared models** — any SwiftData model changes affect multiple views

If your task touches a hot file and you're rebasing against main, expect merge conflicts in these files. Resolve carefully — don't drop other people's changes.

## Auth & Registration Flow

The app uses email + social login (no phone/SMS). The flow:
1. App requests a challenge nonce from `POST /v1/auth/challenge`
2. App generates Noise XX keypair + Ed25519 signing key locally (Keychain)
3. App signs the challenge with Ed25519 and registers via `POST /v1/users/register` (challenge-response — BDEV-183)
4. App obtains a JWT session token via `POST /v1/auth/token` (Ed25519-signed timestamp → HS256 JWT)
5. App uploads public keys to server via `blip-auth/keys` endpoint
6. Other users look up public keys via `blip-auth/lookup?username=...`
7. DMs use Noise XX handshake for E2E encryption
8. JWT tokens are refreshed via `POST /v1/auth/refresh` before expiry

**Critical:** Registration must upload keys to the server. If keys are `null` on the server, the "Add Friend" button will be disabled (by design — `noisePublicKey == nil` guard). If friend requests aren't working, check key upload first.

**Security audit (BDEV-179): COMPLETE (2026-04-08).** All 10 child tickets resolved: registration auth (BDEV-183), JWT session tokens (BDEV-187), PII redaction in DebugLogger (BDEV-188), TLS certificate pinning (BDEV-185), ServerConfig build-time config (BDEV-186), Opus codec integration (BDEV-181), CI/CD pipeline (BDEV-180), app-layer tests (BDEV-182), rate limiting (BDEV-199), DEV_BYPASS (BDEV-184, canceled). Plaintext fallback bug was fixed earlier in PR #109.

## Debug Logging

Use the shared `DebugLogger` for all logging — never use `print()` in production code:

```swift
DebugLogger.shared.log("BLE", "Discovered peer: \(peerID)")
DebugLogger.shared.log("AUTH", "Key upload failed: \(error)")
DebugLogger.shared.log("MESSAGE", "Sending DM to \(recipientUsername)")
```

Categories in use: `APP`, `AUDIO`, `AUTH`, `BLE`, `CLEANUP`, `CRYPTO`, `DB`, `DM`, `EVENT`, `GROUP`, `LIFECYCLE`, `NOISE`, `PEER`, `PRESENCE`, `PROFILE`, `RX`, `SEARCH`, `SELF_CHECK`, `SYNC`, `TX`.

`DebugLogger` also provides PII-safe helpers: `DebugLogger.redact(_:)` (masks all but first/last 2 chars) and `DebugLogger.redactHex(_:)` (masks all but first/last 4 hex chars). Use these when logging usernames, peer IDs, or keys.

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
- **WebSocket relay:** `WebSocketTransport` in BlipMesh handles off-mesh delivery via `blip-relay` worker. Messages route through the relay when BLE peers aren't directly reachable. The relay uses Durable Objects for store-and-forward — queued packets drain automatically when the recipient connects via per-peer serialized drain (promise chaining prevents duplicate delivery on rapid reconnect). Sender PeerID is verified against the authenticated WebSocket connection (bytes 16-23 of packet header must match). Non-addressed packets are broadcast to all other connected peers via fan-out. JWT authentication required (legacy base64 key fallback supported).

## Dependencies (4 only)

| Package | Purpose |
|---|---|
| CryptoKit (Apple, built-in) | Curve25519, ChaChaPoly, SHA256 |
| swift-sodium | Ed25519 signing |
| swift-opus | Voice note + PTT audio codec |
| Sentry (sentry-cocoa) | Crash reporting and ANR detection |

Do not add any other dependencies without explicit approval.

## Files to Skip

Do not read or modify:
- `*.pbxproj`
- `DerivedData/`
- `.build/`
- `build/`
- `*.xcuserdata`
- `.DS_Store`

## Issue Tracker (Bugasura)

Bugasura is the issue tracker (replaced Linear on 2026-04-13). Project: **HeyBlip** (project_id: 135167), team: **Mesh Works** (team_id: 101842), sprint: **Linear Import** (sprint_id: 152746). Issue prefix: **HEY** (e.g., HEY-1186).

**API details:**
- Base URL: `https://api.bugasura.io`
- Auth header: `Authorization: Basic ef611198bd434d11f9ad929b8a3a42efc2232cbc`
- **CRITICAL:** Encoding is `application/x-www-form-urlencoded`, NOT JSON. JSON body is silently ignored.
- Status values are case-sensitive: `"New"`, `"In Progress"`, `"Fixed"`, `"Closed"`

**Key endpoints:**
```bash
# List issues
curl -s -G "https://api.bugasura.io/issues/list" \
  -H "Authorization: Basic ef611198bd434d11f9ad929b8a3a42efc2232cbc" \
  --data-urlencode "team_id=101842" \
  --data-urlencode "project_id=135167"

# Add issue
curl -s -X POST "https://api.bugasura.io/issues/add" \
  -H "Authorization: Basic ef611198bd434d11f9ad929b8a3a42efc2232cbc" \
  --data-urlencode "team_id=101842" \
  --data-urlencode "project_id=135167" \
  --data-urlencode "sprint_id=152746" \
  --data-urlencode "summary=Your summary" \
  --data-urlencode "description=Your description" \
  --data-urlencode "issue_type=BUG" \
  --data-urlencode "severity=HIGH"
```

Note: Delete uses `issue_key` (numeric like 1605380), NOT `issue_id` (like HEY-243).

**Workflow:** Claude Code prompts are stored in Bugasura ticket descriptions. To pick up a task:
1. Fetch the ticket from Bugasura (web UI at https://my.bugasura.io/ or API)
2. Copy the prompt from the ticket description into Claude Code
3. Slack (#tay-tasks, #jmac-tasks) is for **notifications and status updates only** — not for prompts

## Git

- Conventional commits: `type(scope): description`
- Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`
- One logical change per commit
- Never commit with failing tests
- **Branch naming:** `type/HEY-XXX-short-description` (matches Bugasura ticket)
- **Before merging:** Always rebase onto latest `main` and re-run build + tests

### PR and Ticket Handoff — STOP HERE

**NEVER merge your own PRs.** Your job ends at:
1. Branch pushed to `origin`
2. PR opened on GitHub
3. Message posted in `#blip-dev` that the PR is up

John merges all PRs directly via GitHub PAT (updated 2026-04-14). Do not merge, do not approve, do not squash — just notify and stop. Cowork coordinates the pipeline (review prompts, Bugasura updates, merge routing), but the merge click is John's.

**NEVER update Bugasura ticket status.** Cowork manages all ticket transitions (New → In Progress → Fixed → Closed). Do not touch ticket status at any point during your work.

## Execution Model

1. Understand the task and read relevant code
2. Plan the approach (check design spec if UI-related)
3. Implement with minimal blast radius
4. Verify: build with xcodebuild, test with `swift test --package-path`
5. Deliver only when verified — green build, passing tests

Do not ask clarifying questions when the answer is in the codebase or the design spec. Execute autonomously.
