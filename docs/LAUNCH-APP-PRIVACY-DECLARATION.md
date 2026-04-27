# App Store App Privacy Nutrition Label — Declaration

**Audience:** John (paste into App Store Connect → App Privacy)
**Ticket:** [BDEV-365](https://heyblip.atlassian.net/browse/BDEV-365)
**Last reviewed:** 2026-04-27
**Source-of-truth crosscheck:** Must agree with `App/Info.plist` purpose strings (BDEV-359), `docs/LAUNCH-MODERATION-PROCESS.md` (BDEV-361), and the public privacy policy at `https://heyblip.au/privacy`.

## How to use this doc

Open App Store Connect → My Apps → HeyBlip → App Privacy. You'll see a list of data-type categories. For each category, answer: *do you collect this?* If yes, declare the specific data points, whether they're linked to user identity, whether they're used to track the user across other apps/sites, and the purposes.

Use the answers below as your script. Apple's UI sometimes asks slightly different questions than this doc lists — when in doubt, **declare more than you actually collect**, not less. Apple penalises under-declaration; over-declaration is fine.

## Apple's "data collection" definition

From Apple's developer site, you "collect" data when "the data leaves the device in any way that's readable by you, your service providers, partners, or third parties". This includes:
- Data sent to your servers, even briefly (store-and-forward counts)
- Data sent to analytics / crash-reporting providers
- Data sent to ad networks (n/a — HeyBlip has no ad SDKs)

Data is NOT "collected" if:
- It's stored only on the user's device (e.g. SwiftData local DB)
- It's processed in a way that's not readable by anyone (e.g. ciphertext where no party holds the key)

HeyBlip's E2E messages are technically transmitted server-side (relay store-and-forward) but the relay holds ciphertext only. Per Apple's guidance, that **is** still collection of "User Content" — Apple's definition includes transient encrypted storage. Declare conservatively.

## Declarations

Use this section as a literal copy-paste guide. Apple's UI presents each category one at a time.

### Contact Info

**Email Address — YES, collect, linked to user, NOT used for tracking.**

What you collect: a SHA-256 hash of the user's email address (we do not store the plaintext email after registration completes).

Purposes:
- **App Functionality** — used to verify ownership at registration via OTP and to recover an account on a lost device.

### Identifiers

**User ID — YES, collect, linked to user, NOT used for tracking.**

What you collect: cryptographic identity (Noise X25519 public key, Ed25519 public key) generated locally and uploaded to the registry. A username chosen at sign-up. A PeerID derived from the Ed25519 public key.

Purposes:
- **App Functionality** — peer discovery, message routing, friend lookup, signature verification.
- **Account Creation** — user identity in the system.

**Device ID — NO.** HeyBlip does not collect IDFA, IDFV, or any device-level identifier.

### User Content

**Messages — YES, collect, linked to user, NOT used for tracking.**

What you collect: encrypted message content transits through the WebSocket relay during off-mesh delivery. The relay stores ciphertext briefly (max 1 hour, max 50 packets per recipient) for store-and-forward. We never hold the plaintext.

Purposes:
- **App Functionality** — store-and-forward delivery for off-mesh recipients. Relay buffers expire on delivery or after the TTL.

**Photos or Videos — YES, collect, linked to user, NOT used for tracking.**

What you collect: image attachments in chats are encrypted and traverse the same path as messages (mesh + relay). Same store-and-forward characteristics.

Purposes:
- **App Functionality** — same as messages.

**Audio Data — YES, collect, linked to user, NOT used for tracking.**

What you collect: voice notes (Opus-encoded audio) follow the same path.

Purposes:
- **App Functionality** — same as messages.

**Customer Support — NO.** Email-based support enquiries to `support@heyblip.au` are operationally handled but Apple's nutrition label is for in-app data flows, not external email correspondence.

**Other User Content — NO.**

### Location

**Coarse Location — YES, collect, linked to user, NOT used for tracking.**

What you collect: when the user opts into location-sharing per friend (default OFF), the friend's app receives a coarse-resolution geohash of the sender's location via the encrypted mesh. The relay never sees plaintext location — only end-to-end-encrypted ciphertext. Geohashes are also used for proximity-based event channel discovery (joining the channel for the festival you're physically inside).

Purposes:
- **App Functionality** — friend-finder map, event-channel discovery, SOS broadcast (for the recipient to know roughly where to go).

**Precise Location — YES, collect, linked to user, NOT used for tracking.**

What you collect: same as coarse, but at higher resolution, only when the user has enabled "precise location" in iOS Settings AND opted into sharing per friend. Used for the same purposes; the user controls the resolution.

Purposes:
- Same as coarse.

### Diagnostics

**Crash Data — YES, collect, NOT linked to user, NOT used for tracking.**

What you collect: stack traces, signal codes, and breadcrumb logs from app crashes. Sent to Sentry. We have Sentry configured with `sendDefaultPii = false`, so no email / IP / username is attached to crash events. The app does set a `userId` tag for tied tracking — that **is** linked to the cryptographic UserID we already declared in Identifiers, so this category needs to declare "linked to user" if you want strict accuracy.

**Recommendation: declare as Linked to User** to be conservative. We DO tag crashes with the app's internal UserID via `SentrySDK.setUser(userId:)`. That's a link.

Purposes:
- **App Functionality** — diagnose crashes and stability issues.
- **Analytics** — understand which versions / paths are most affected.

**Performance Data — YES, collect, linked to user (same as Crash), NOT used for tracking.**

What you collect: ANR (App Not Responding) events, slow-render traces (Sentry tracesSampleRate = 0.2 in production).

Purposes:
- **App Functionality** — performance troubleshooting.
- **Analytics**.

**Other Diagnostic Data — NO.** Categorise additional diagnostics under Crash Data or Performance Data.

### Usage Data

**Product Interaction — NO.** HeyBlip does not collect "user tapped X button at time T" event analytics. The Sentry breadcrumb log captures BLE / mesh / cryptographic events for crash debugging, but those are operational logs scoped to crash-context, not product-analytics events. They count under Diagnostics.

**Advertising Data — NO.** We do not show ads.

**Other Usage Data — NO.**

### Purchases

**Purchase History — YES, collect, linked to user, NOT used for tracking.**

What you collect: Apple In-App Purchase transaction IDs for message-pack purchases, sent to our backend for receipt validation and balance accounting.

Purposes:
- **App Functionality** — message-balance accounting.

### Other Data Types — NOT COLLECTED

Declare each of these as "Not Collected":

- **Health & Fitness** — Health, Fitness data
- **Financial Info** — Payment Info, Credit Info, Other Financial Info (Apple handles IAP payment; we never see the card)
- **Sensitive Info** — Race / ethnicity, sexual orientation, pregnancy / childbirth, disability, religion / belief, politics, trade union, genetic, biometric
- **Contacts** — User's address book
- **Browsing History** — Browsing activity outside HeyBlip
- **Search History** — Searches inside HeyBlip
- **Other Data**

## Tracking declaration

Apple defines "tracking" as "linking user or device data collected from your app with user or device data collected from other companies' apps, websites, or offline properties for targeted advertising or advertising measurement purposes, or sharing user or device data with data brokers."

**HeyBlip does NOT track users.** Declare:
- **No, we don't track users.**

This is a top-level question separate from the per-category "used for tracking" answers (which are all "No" above).

## Data linked to user — summary

For App Store Connect's summary card:

- **Data linked to you:** Email Address, User ID, Messages, Photos / Videos, Audio Data, Coarse Location, Precise Location, Crash Data, Performance Data, Purchase History.
- **Data not linked to you:** None — even diagnostics are tagged with the user ID for crash troubleshooting.
- **Data used to track you:** None.

## Crosschecks before submitting

Before you click submit in App Store Connect, run these mental crosschecks:

1. **Info.plist purpose strings** (`App/Info.plist`) match the categories declared above:
   - `NSLocationWhenInUseUsageDescription` + `NSLocationAlwaysAndWhenInUseUsageDescription` → Location declared ✓
   - `NSCameraUsageDescription` → Photos or Videos (camera input) declared ✓
   - `NSPhotoLibraryUsageDescription` → Photos or Videos (library input) declared ✓
   - `NSMicrophoneUsageDescription` → Audio Data declared ✓
   - `NSBluetoothAlwaysUsageDescription` → BLE peer discovery; not a "collected" data category per Apple's privacy taxonomy (BLE is transport, not data we collect about the user).
2. **Privacy policy at `https://heyblip.au/privacy`** lists everything the App Privacy label declares. Update the policy if needed before submitting.
3. **`docs/LAUNCH-MODERATION-PROCESS.md`** mentions retention windows that match the declarations above (relay store-and-forward 1 hour, server logs 30 days).

## Pre-submission self-check

Use this checklist as you fill out App Store Connect:

- [ ] Contact Info → Email Address declared (linked, not tracking)
- [ ] Identifiers → User ID declared (linked, not tracking)
- [ ] User Content → Messages, Photos / Videos, Audio Data declared (linked, not tracking)
- [ ] Location → Coarse + Precise declared (linked, not tracking)
- [ ] Diagnostics → Crash + Performance declared (linked — see note above)
- [ ] Purchases → Purchase History declared (linked, not tracking)
- [ ] All other categories declared "Not Collected"
- [ ] Tracking question answered "No"
- [ ] Privacy policy URL set to `https://heyblip.au/privacy`

## When this changes

Re-run this declaration whenever:

- A new third-party SDK is added (would change tracking / data flows).
- A new endpoint sends user data to the server beyond what's listed here.
- The privacy policy is updated.
- Apple updates their App Privacy categories (typically once a year at WWDC).

Update this doc + App Store Connect together — never one without the other.
