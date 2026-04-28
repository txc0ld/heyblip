# Blip — Claude Code Instructions

## Project Identity

HeyBlip is a Bluetooth mesh chat app for events. iOS-first, SwiftUI, MVVM. The app lets users chat at events (festivals, sporting events, ultra marathons, concerts, any high-density gathering) via BLE mesh when mobile reception is unavailable. Internal code names remain Blip.

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

**App-level tests** live in `Tests/` (`ServiceTests/`, `ViewModelTests/`, `SwiftDataSchemaValidationTests.swift`) and only run through the `BlipTests` target — they depend on the `Blip` app target and cannot run via `swift test`. CI does not currently execute these; they run locally via Xcode's test action on the `Blip` scheme. If you touch code covered by these tests, run them in Xcode before delivering.

**Strict concurrency:** `project.yml` sets `SWIFT_STRICT_CONCURRENCY: complete`, so local builds surface all concurrency warnings. CI's final app-build step overrides this to `minimal` (`-Xfrontend -strict-concurrency=minimal`) — don't rely on CI to catch concurrency issues; fix them locally.

**Schemes and BLE UUID:** Two schemes exist with different BLE service UUIDs to avoid colliding on the same physical hardware:

| Scheme | Config | `BLE_SERVICE_UUID` env |
|---|---|---|
| `Blip` (default) | Debug, also sets `-DBLE_UUID_DEBUG` | `FC000001-0000-1000-8000-00805F9B34FA` |
| `Blip-Release` | Release | `FC000001-0000-1000-8000-00805F9B34FB` |

The `...FB` UUID is the production/characteristic UUID in the protocol spec. Use the default `Blip` scheme for dev; devs running debug + release builds side-by-side will see them on separate mesh UUIDs.

## CI

Pipeline: `.github/workflows/ci.yml` (runs on PR and push to `main`). Two jobs:

- **`ios`** (macos-15, Xcode 16.x): `brew install xcodegen libsodium` → `xcodegen generate` → all three `swift test --package-path ...` (BlipMesh retries once on failure) → `xcodebuild` app build with `-strict-concurrency=minimal`.
- **`server-tests`** (ubuntu-latest): `npm ci && npm test` inside `server/auth/`. `server/cdn/` and `server/relay/` don't have test suites.

Also: `.github/workflows/deploy-testflight.yml` handles TestFlight deploys.

When making PR-ready changes, locally reproduce what CI does: run the three `swift test` commands + the `xcodebuild` command from the Build Configuration section above.

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
- **`Sources/Services/MessageService.swift`** — core message send/receive, encryption routing, relay transport. Extensions in `MessageService+FriendRequests.swift` and `MessageService+Handshake.swift`. Still a hot file but conflict risk is reduced.
- **`Packages/BlipMesh/Sources/BLEService.swift`** — BLE peripheral/central management, connection state, broadcast backpressure queues. Note: lives in `Packages/BlipMesh/`, not `Sources/Services/`.
- **`Packages/BlipMesh/Sources/WebSocketTransport.swift`** — relay client, reconnection, token refresh.
- **`Packages/BlipCrypto/Sources/NoiseSessionManager.swift`** — handshake state machine, tiebreaker, session cache.
- **`Packages/BlipProtocol/Sources/FragmentAssembler.swift`** — fragment reassembly; public API now takes `(fragment, from: PeerID)` to avoid cross-peer contamination.
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
- **Fragment reassembly:** keyed by `(senderPeerID, fragmentID)` — never by `fragmentID` alone. Two peers picking the same random 4-byte fragmentID must not cross-contaminate. Public API: `FragmentAssembler.receive(_ fragment: Fragment, from senderID: PeerID)`.
- **Media payload format:** `buildMediaPayload`/`parseMediaPayload` symmetric pair — `[UUID UTF-8 (36B)][0x00][duration 8B, voice notes only][mediaBytes]`. The parser is *not* self-describing for duration; callers pass `hasDuration:` matching the subType (voice notes yes, images no). `ParsedMediaPayload.messageID` is `Optional<UUID>` — when the leading prefix is missing/non-UTF-8, the parser returns `nil` and the receive pipeline drops the message rather than indexing it under a synthesised UUID (the old behaviour broke dedup on every retransmit).
- **Encryption:** Noise_XX_25519_ChaChaPoly_SHA256 via CryptoKit + swift-sodium for Ed25519
- **BLE Service UUID:** `FC000001-0000-1000-8000-00805F9B34FB`
- **BLE Characteristic UUID:** `FC000002-0000-1000-8000-00805F9B34FB`
- **BLE backpressure:** `BLEService.broadcast` honours `bleUpdateValue` return value and `canSendWriteWithoutResponse`. Deferred broadcasts are queued (bounded to `maxPendingBroadcasts = 32`) and flushed on `peripheralManagerIsReady(toUpdateSubscribers:)` / `peripheralIsReady(toSendWriteWithoutResponse:)`. Addressed sends surface notify-path backpressure via `TransportError.unavailable` rather than pretending success.
- **WebSocket client send:** `state` + `webSocketTask` are captured in a single `lock.withLock` to avoid a TOCTOU race that previously caused addressed DMs to throw `.unavailable` → the mesh layer would fall back to *broadcast*. That fallback has been removed; send errors are now surfaced via `TransportDelegate.transport(_:didFailDelivery:to:)` so the mesh layer can re-route instead of silently leaking DMs.
- **WebSocket relay:** `WebSocketTransport` in BlipMesh handles off-mesh delivery via `blip-relay` worker. Messages route through the relay when BLE peers aren't directly reachable. The relay uses Durable Objects for store-and-forward — queued packets drain automatically when the recipient connects via per-peer serialized drain (promise chaining prevents duplicate delivery on rapid reconnect). Sender PeerID is verified against the authenticated WebSocket connection (bytes 16-23 of packet header must match). Non-addressed packets are broadcast to every peer whose **PeerID hex** differs from the sender (not by WebSocket object identity — that breaks under rapid reconnect). JWT authentication required; legacy base64-key auth is gated behind the server-side `ALLOW_LEGACY_AUTH` env flag and must not be set in production.
- **Noise handshake Task lifecycle:** timeout + retry Tasks are stored in `handshakeTimeoutTasks` / `handshakeRetryTasks` on `MessageService` and are deterministically cancelled on session establishment, timeout, and `deinit`. Never spawn an unstored `Task {}` for handshake work.
- **Persistence on receive:** `ChatViewModel.handleReceivedMessage` and `applyStatusChange` MUST save the SwiftData context after mutating `Channel.lastActivityAt`, `Channel.unreadCount`, or `Message.statusRaw`. Without the save, the chat-list ordering, unread badges, and delivery/read indicators all roll back on cold launch. Status updates that arrive while a different channel is open also persist via fetch-then-save instead of only mutating `activeMessages[idx]`.
- **Foreground notification suppression:** `NotificationService.setActiveChannel(_:)` is set by `ChatViewModel.openConversation` and cleared by `closeConversation` / `clearTransientConversationState`. The `willPresent` delegate suppresses the banner (badge-only) when an incoming `newMessage` payload's `channelID` matches the active one — the user is already looking at the bubble. SOS is unconditional — it always interrupts.
- **Voice note playback singleton:** `VoiceNotePlaybackCoordinator.shared` issues a token to whichever bubble starts playing. Other bubbles observe `activePlayerToken` and stop themselves on mismatch. Each bubble still owns its own `AudioService` (per-bubble UI state), but the coordinator guarantees a single audio session is driving output. Don't bypass the coordinator — overlapping voice notes was the symptom we're guarding against.
- **AudioService lifecycle observers:** `installSystemObservers` (called lazily from `configureAudioSession`) subscribes to `AVAudioSession.interruptionNotification`, `routeChangeNotification`, and `UIApplication.didEnterBackgroundNotification`. Recording is cancelled on interruption-began, app-background, and (for playback) old-device-unavailable route changes. Timer creation is lock-protected so a rapid cancel→start doesn't observe a stale-but-still-firing timer.
- **Image bubble memory:** `ChatView.messages` only forwards `attachment.thumbnail` to `MessageBubble`. Full-resolution bytes are loaded on demand via `imageDataForViewer(messageID:)` when the user taps a bubble and the `ImageViewer` is presented. Don't pass `attachment.fullData` into the chat scroll — long histories of 500KB+ images blow memory linearly.
- **Friend action race guard:** `FriendsListView` keeps an `actionsInFlight: Set<UUID>` keyed by `Friend.id`. `acceptFriendRequest` / `removeFriend` / `blockFriend` / `unblockFriend` / `declineFriend` all `claimAction(for:)` first, returning early if a previous async run is still pending. This stops Accept-then-Decline double-taps from racing two flows against the same record.
- **Tap-to-DM from Nearby:** `AppCoordinator.openDM(withUsername:)` resolves a username to a SwiftData `User`, asks `ChatViewModel.createDMChannel(with:)` to find/create the thread, then sets `pendingNotificationNavigation = .conversation(channelID:)`. `MainTabView` switches to `.chats` and `ChatListView` pushes the chat — this is the same plumbing notification taps use.

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

## Issue Tracker (Jira)

**Jira BDEV** is the issue tracker as of 2026-04-25. It replaced Notion (which replaced Bugasura, which replaced Linear on 2026-04-13). Issue prefix is **`BDEV-N`** — Jira's auto-numbering. The 366 imported tickets cover **BDEV-2 → BDEV-367**; new tickets continue from BDEV-368+.

**Site:** https://heyblip.atlassian.net  
**Jira project:** `BDEV` ("HeyBlip"), company-managed Scrum  
**Confluence space:** `BLIP` ("HeyBlip") — linked from BDEV → Docs tab. Team home at https://heyblip.atlassian.net/wiki/spaces/BLIP

**Issue types** (default Scrum): `Bug`, `Task`, `Story`, `Epic`, `Subtask`. Old Notion-era types (`IMPROVEMENT`, `POLISH`, `SUGGESTION`, `TECH-DEBT`) were collapsed into `Task` during import.

**Statuses:** `To Do`, `In Progress`, `Done`. Resolution auto-set to `Done` on transition to Done.

**Custom fields** (every imported ticket has these populated):
- `HEY ID` (`customfield_10039`) — old Bugasura ID, e.g. `HEY-1334`. Load-bearing for cross-reference.
- `Original BDEV ID` (`customfield_10040`) — old Linear-era BDEV-N
- `Notion URL` (`customfield_10041`) — link back to original Notion page
- `Bugasura URL` (`customfield_10042`) — historical link only; the Bugasura project was deleted 2026-04-26 so these URLs 404. Kept as provenance.

The same metadata is also embedded as plain text in each issue's description, so JQL `description ~ "HEY-1334"` works as a fallback.

**Find an old ticket by its HEY-N:**
```
JQL: "HEY ID" = "HEY-1334"
```

**Filing a ticket via REST API — every new ticket MUST include a `parent` Epic:**
```bash
EMAIL="macca.mck@gmail.com"
TOKEN=$(security find-generic-password -a "$EMAIL" -s atlassian-api-token-heyblip -w)
curl -X POST -u "$EMAIL:$TOKEN" -H "Content-Type: application/json" \
  "https://heyblip.atlassian.net/rest/api/3/issue" -d '{
    "fields": {
      "project": {"key":"BDEV"},
      "summary": "[TAG] short description",
      "issuetype": {"name":"Bug"},
      "priority": {"name":"High"},
      "parent": {"key":"BDEV-385"},
      "labels": ["audit-gaps-apr-2026"]
    }
  }'
```
Atlassian rate limits are aggressive on API tokens — sleep ≥1s between calls; throttling appears as 401/404 (not 429).

**BDEV Epic catalog (set up 2026-04-26) — every new ticket gets a parent Epic from this list:**

| Epic | Key | Tag pattern |
|---|---|---|
| Push Notifications | BDEV-380 | `[PUSH]`, `[APNS]`, `[NSE]` (and push-specific `[APP]`) |
| App Store Launch | BDEV-381 | `[LAUNCH]` |
| Auth & Identity | BDEV-382 | `[AUTH]` |
| Chat Experience | BDEV-383 | `[CHAT]`, `[DM]`, `[ATTACHMENT]`, `[REACTION]` (and chat-feature `[APP]`) |
| Engineering Hygiene | BDEV-384 | `[REFACTOR]`, `[BUILD]`, `[OPS]`, `[POLISH]`, `[DOCS]`, `[PROCESS]` |
| Handshake & Transport | BDEV-385 | `[NOISE]`, `[BLE]`, `[CRYPTO]`, `[RELAY]` |
| Observability | BDEV-386 | `[OBS]`, `[OBSERVABILITY]`, `[SENTRY]`, `[LOG]` |
| Test Infrastructure | BDEV-387 | `[TEST]`, `[CI]` |
| Web Site | BDEV-388 | `[WEB]` |

If a ticket genuinely doesn't fit any of the 9, file without a parent and ping John in `#blip-dev` for a 10th Epic — don't default to "Engineering Hygiene" as a misc bucket. Full catalog + decision tree in `docs/PM/memory/reference_epic_catalog.md`.

**Notion HeyBlip workspace** — still exists with the original Tasks DB but is now a read-only archive. New work doesn't go there.

**Bugasura** — project deleted 2026-04-26. The `Bugasura URL` custom field on imported tickets now 404s; use `HEY ID` for cross-reference instead.

**Documentation:** Confluence is the team docs home. Decisions log uses Confluence's `/decision` inline action with stable `DEC-N` IDs. Components reference mirrors the SPM package layout — see https://heyblip.atlassian.net/wiki/spaces/BLIP/pages/524291/Components.

**Workflow:** To pick up a task:
1. Fetch the Jira ticket via REST API (`GET /rest/api/3/issue/BDEV-N`) or by URL `https://heyblip.atlassian.net/browse/BDEV-N`
2. Read the description for repro steps + linked Notion URL for historical context
3. Slack (#tay-tasks, #jmac-tasks) is for **notifications and status updates only** — not for prompts

For full Jira and Confluence reference, see:
- `docs/PM/memory/reference_jira_workspace.md`
- `docs/PM/memory/reference_confluence_workspace.md`

## Git

- Conventional commits: `type(scope): description`
- Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`
- One logical change per commit
- Never commit with failing tests
- **Branch naming:** `type/BDEV-XXX-short-description` (matches the Jira BDEV-N ticket key). For tickets that pre-date the migration, you may also see `type/HEY-XXX-...` branches still open — these are valid; the BDEV ticket carries the old HEY-N as a custom field for traceability.
- **Before merging:** Always rebase onto latest `main` and re-run build + tests

### PR and Ticket Handoff — STOP HERE

**NEVER merge your own PRs.** Your job ends at:
1. Branch pushed to `origin`
2. PR opened on GitHub
3. Message posted in `#blip-dev` that the PR is up
4. **CI watcher loop started** — see `feedback_pr_ci_watcher.md` for the template. Per-PR `/loop 1m` cron that surfaces FAILURE / CLEAN transitions until terminal, then self-cancels. John shouldn't have to ping back to ask "is it green yet?"

John merges all PRs directly via GitHub PAT (updated 2026-04-14). Do not merge, do not approve, do not squash — just notify and stop. Cowork coordinates the pipeline (review prompts, Jira updates, merge routing), but the merge click is John's.

**Jira transitions — what you can and can't do.** Workflow as of 2026-04-28 (BDEV-378): `To Do → In Progress → Verifying → Done`, with a `Done (no device verification)` skip path direct from `In Progress`. You CAN move tickets `To Do → In Progress` when you start work, and add comments / paste PR URL into the description. You MUST NOT transition tickets to `Verifying` or `Done` directly — `In Progress → Verifying` is owned by the GitHub merge automation rule (auto-fires when a `BDEV-N` PR merges), and `Verifying → Done` requires a verification comment (commit SHA, build SHA, smoke-trace note, or `skip: <reason>`) and is owned by PM/Cowork or the verifier on a per-ticket basis. The `Done (no device verification)` skip path is for CI / docs / refactor / observability changes only — anything user-facing, transport, crypto, or push must go through Verifying. Tickets transitioned via the skip path auto-acquire a `done-no-device-verification` label so abuse is auditable. Set `Assignee` → yourself when you claim a ticket.

**The merge rule is the hard one: only John merges PRs.** Engineer-agents and PM/Cowork stop at branch pushed + PR opened + #blip-dev notification + Jira ticket linked. Never click merge yourself, never use `gh pr merge`. PM may merge only on John's explicit per-instance authorization (e.g. "merge it") — match scope precisely, don't extrapolate.

## Execution Model

1. Understand the task and read relevant code
2. Plan the approach (check design spec if UI-related)
3. Implement with minimal blast radius
4. Verify: build with xcodebuild, test with `swift test --package-path`
5. Deliver only when verified — green build, passing tests

Do not ask clarifying questions when the answer is in the codebase or the design spec. Execute autonomously.
