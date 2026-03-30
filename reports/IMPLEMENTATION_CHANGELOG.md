# Implementation Changelog

## What Changed

### 1. App shell and feature wiring

- `BlipApp` now passes the shared `AppCoordinator` into `MainTabView`.
- `AppCoordinator` now owns and starts `ChatViewModel`, `FestivalViewModel`, and `ProfileViewModel`.
- runtime teardown/startup now clears observers, transports, geofencing, delegate wiring, and feature models cleanly.

Resolves:

- composition-root drift
- stale sign-out/onboarding state
- feature tabs bypassing live runtime dependencies

### 2. Chat and DM path

- `ChatListView` now consumes the injected shared chat VM instead of constructing a private messaging stack.
- DM creation now resolves persisted users before creating membership/channel records.
- chat regressions are covered by new tests for channel creation and reuse.

Resolves:

- nearby-to-chat runtime drift
- duplicate/detached DM channel creation risk

### 3. Festival and profile/settings truth surfaces

- festival tab now renders injected runtime state, sync/error banners, and honest empty states instead of sample-backed assumptions.
- settings now bind to persisted `UserPreferences`.
- onboarding seeds preferences.
- sign-out now clears identity and the local store instead of only flipping `AppStorage`.

Resolves:

- demo/live ambiguity
- inconsistent settings persistence
- fake sign-out behavior

### 4. Unsupported commerce/account affordances

- verified-profile purchase no longer mutates local state as if verification were real.
- message-pack verified CTA copy now says the flow is unavailable until wired.
- unsupported recovery/export/delete actions remain visible but explicitly unavailable.

Resolves:

- misleading verification/account UX

### 5. Auth worker hardening

- registration and sync inputs are sanitized.
- client-controlled `isVerified` and `messageBalance` fields are ignored.
- receipt verification now fails closed with `501` when not configured.
- `DEV_BYPASS` default in `wrangler.toml` is now `false`.

Resolves:

- privilege escalation risk
- accidental production bypass posture
- fake server-side verification semantics

### 6. Documentation honesty

- README security and feature copy now distinguishes live packet signing from incomplete end-to-end encryption wiring.

Resolves:

- documentation / implementation drift

## Intentionally Deferred

- full Noise session wiring for confidential private-message transport
- real server-backed verified-profile commerce flow
- cleanup of pre-existing package failures in `BlipMesh` and `BlipCrypto`
- broader Swift 6 concurrency warning cleanup
