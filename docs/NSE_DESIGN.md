# NSE Design — Blip Notification Service Extension

This document explains how Blip's Notification Service Extension (NSE) enriches
incoming Apple Push Notification (APNs) payloads, why it does not decrypt
content, and the operational prerequisites for shipping it.

## 1. Why no decryption in NSE

The NSE is a short-lived, sandboxed process that iOS wakes when an APNs
payload with `mutable-content: 1` arrives. It gets ~30s of wall-clock time
before the system gives up and delivers the original payload unchanged.

Blip's transport security is Noise_XX_25519_ChaChaPoly_SHA256. Session state
lives in the main app's `NoiseSessionManager` — a 4h session cache, 1h rekey
cadence, in-memory with optional persistence. That state cannot be moved into
the NSE for several reasons:

- **Cross-process actor coordination.** Sharing live Noise session state
  between the app and the NSE would require a cross-process lock (File
  Coordination, XPC, or a shared CoreData/SQLite store). The NSE would need
  to mutate session counters and rekey material while the main app may also
  be running — the two processes cannot hold the Noise state machine
  simultaneously without risk of nonce reuse.
- **Rekey on every NSE wake.** The NSE is cold-started per delivery, so it
  couldn't keep in-memory session cache. Falling back to persisted state
  would force us to either (a) rekey on every push or (b) share long-lived
  session keys across the process boundary — both worse than the alternative.
- **Zero-knowledge boundary.** The `blip-relay` worker is already
  zero-knowledge: payloads transit encrypted; the relay only sees
  addressing metadata. Moving decryption out of the main app, into a system
  daemon child, blurs the boundary for no security or UX win.

Instead, the NSE does **zero-knowledge enrichment**: display names and
channel names only, from an App-Group JSON cache that the main app writes
whenever friends/channels change. The NSE never reads the Keychain, never
decrypts a packet, never talks to the network.

## 2. Cache layout

**Path.** `<App Group container>/NotificationEnrichmentCache.json` where the
App Group is `group.com.heyblip.shared`.

**Schema** (duplicated verbatim in
`NotificationServiceExtension/NotificationEnrichmentCacheReader.swift` and
`Sources/Services/NotificationEnrichmentCache.swift`):

```swift
struct NotificationEnrichmentCache: Codable, Sendable {
    struct Friend: Codable, Sendable {
        let peerIdHex: String
        let displayName: String
        let avatarURL: String?
    }
    struct Channel: Codable, Sendable {
        let id: UUID
        let name: String
        let kind: String
    }
    var friends: [String: Friend]   // keyed by peerIdHex
    var channels: [String: Channel] // keyed by channel UUID string
    var updatedAt: Date
}
```

**Atomic replace.** The writer (main-app target) writes to a temp path in the
App Group container and renames to `NotificationEnrichmentCache.json`. This
guarantees the NSE never observes a half-written file.

**Stale cache behaviour.** The NSE tolerates any age. If a friend was added
seconds before the push and isn't in the cache yet, the NSE renders
"Unknown contact"; the main app will show the correct name when the user
opens the app. This is a deliberate tradeoff — we never block delivery on a
cache refresh.

## 3. Budget handling

iOS allocates the NSE ~30s of wall-clock time. Our enrichment path is
dominated by a single `Data(contentsOf:)` read of a small JSON file from the
App Group container — typically sub-millisecond.

If we ever do exceed the budget, `serviceExtensionTimeWillExpire` returns
whatever `bestAttempt` content we already have — that's the original APNs
payload we copied into a mutable container at the top of `didReceive`.
Generic copy ("New message") beats silent drop.

## 4. Failure modes

| Failure | Outcome |
|---|---|
| App Group entitlement not provisioned | `containerURL(forSecurityApplicationGroupIdentifier:)` returns `nil` → cache is `nil` → generic copy ("Unknown contact", "New message"). |
| Cache file missing (fresh install, not yet written) | `Data(contentsOf:)` throws → `try?` yields `nil` → generic copy. |
| Cache file corrupt or schema drift | `JSONDecoder.decode` throws → `try?` yields `nil` → generic copy. |
| Unknown `blip.type` in payload | Switch hits `default` → original content preserved (forward compat for future types). |
| No `blip` key at all in `userInfo` | Early return after mutable copy → passthrough unchanged. |
| `mutableCopy()` surprisingly fails | Passthrough with `contentHandler(request.content)`. |

No code path can `fatalError`, force-unwrap, or throw out of `didReceive`.

## 5. What NSE does NOT do

- **No network.** No URLSession, no WebSocket, no CDN fetch.
- **No Noise.** No CryptoKit handshake, no decryption attempt.
- **No SwiftData.** The SwiftData model container lives in the main app;
  the NSE writes nothing to disk outside the UNNotificationContent it
  returns.
- **No Keychain read.** `keychain-access-groups` is intentionally omitted
  from `BlipNotificationService.entitlements`.
- **No Sentry SDK.** The Sentry SDK is heavy (symbol upload, context
  capture) and runs background tasks the NSE has no budget for. We rely on
  main-app observability. If an NSE bug surfaces, it surfaces as a generic
  notification on real devices — we fix it on the next build.
- **No rich media attachments (yet).** Future work could add image
  attachments for avatars by downloading from `blip-cdn` inside the NSE,
  but that requires network access and is out of scope for HEY-1321.

## 6. Bundle IDs + App Groups matrix

| Target | Config | Bundle ID | Entitlements | `aps-environment` |
|---|---|---|---|---|
| Blip (app) | Debug | `au.heyblip.Blip.debug` | `App/Entitlements/Blip.debug.entitlements` | `development` |
| Blip (app) | Release | `au.heyblip.Blip` | `App/Entitlements/Blip.entitlements` | `production` |
| BlipNotificationService | Debug | `au.heyblip.Blip.debug.notifications` | `App/Entitlements/BlipNotificationService.debug.entitlements` | (none) |
| BlipNotificationService | Release | `au.heyblip.Blip.notifications` | `App/Entitlements/BlipNotificationService.entitlements` | (none) |

**App Group** — all four variants share `group.com.heyblip.shared`. This is
intentional: the NSE reads a cache written by the main app, and both debug
and release builds of the main app write to the same cache so developers
flipping configs don't get stale enrichment.

**Keychain access group** — `$(AppIdentifierPrefix)au.heyblip.Blip` on both
Debug and Release main-app entitlements (NOT the debug bundle suffix). This
keeps the Noise keypair, Ed25519 signing key, and JWT session tokens
consistent when a developer toggles between Debug and Release builds on the
same device. Keychain access groups are namespaced by the AppIdentifierPrefix
(team ID), so sharing across two bundle IDs on the same team is safe. The NSE
never reads Keychain and intentionally omits this key.

**`aps-environment` placement** — lives only on the main app entitlements
files. The NSE does not register for push; it only runs when iOS hands it a
payload already delivered to the main app's bundle. APNs payload routing is
keyed on the main app's bundle ID.

## 7. Ops pre-reqs

Before the first archive/TestFlight build, the Apple Developer Portal must
have the following registered:

**App IDs** (Identifiers → App IDs, all on team `3WM8QNMY94`):
- `au.heyblip.Blip` — Push Notifications capability ON, App Groups ON
- `au.heyblip.Blip.debug` — Push Notifications capability ON, App Groups ON
- `au.heyblip.Blip.notifications` — App Groups ON (no Push; NSE doesn't register)
- `au.heyblip.Blip.debug.notifications` — App Groups ON

**App Group** (Identifiers → App Groups):
- `group.com.heyblip.shared` — associated with all four App IDs above

**APNs Keys** (Keys, under the team):
- One `.p8` APNs Auth Key with Apple Push Notifications service enabled; the
  relay/auth worker uses this to mint JWTs for APNs HTTP/2. See
  `docs/OPS_APNS.md` (not owned by this slice) for rotation policy.

**Provisioning profiles:** refresh both Debug and Release profiles for all
four App IDs after the capabilities above are added. If `xcodebuild`
archives fail with "missing entitlement", the profile is stale — regenerate.

**Verification before first TestFlight:**
1. Xcode → main app target → Signing & Capabilities → confirm App Groups
   shows `group.com.heyblip.shared` checked, Push Notifications is listed.
2. Same on the BlipNotificationService target.
3. `xcodebuild -scheme Blip -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGN_IDENTITY="" CODE_SIGNING_ALLOWED=NO -quiet` passes.
4. On a real device, a push sent through `blip-relay` staging lands with an
   enriched title (sender display name) for a known friend.
