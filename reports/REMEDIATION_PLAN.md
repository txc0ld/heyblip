# Remediation Plan

## Ordered Execution Plan

### A. Critical defects

1. Enforce coordinator-owned feature composition
   - Why it matters: fixes the broadest class of chat/profile/event/runtime drift
   - Root cause: app shell allowed tabs to create or prefer private state
   - Affected systems: `BlipApp`, `MainTabView`, `AppCoordinator`, chat/event/profile views
   - Fix strategy: inject coordinator-owned view models/services and centralize teardown/startup
   - Dependencies: none
   - Validation: native build, chat tests
   - Linear update: yes, because it explains why multiple surface bugs shared one cause

2. Harden auth worker trust boundary
   - Why it matters: client-controlled privilege fields and dev bypass are release-blocking
   - Root cause: development shortcuts were left in production-facing paths
   - Affected systems: `server/auth`
   - Fix strategy: sanitize inputs, ignore privileged client fields, default bypass off, fail receipt verification closed
   - Dependencies: none
   - Validation: auth Vitest suite
   - Linear update: yes

### B. Functional breakage

3. Use persisted users and shared chat state for DM creation
   - Why it matters: nearby-to-chat flow must use real data, not detached service instances
   - Root cause: chat tab instantiated its own messaging stack and DM path
   - Affected systems: `ChatListView`, `ChatViewModel`, `MessageService`
   - Fix strategy: inject shared view model, create DMs from persisted users, keep previews aligned
   - Dependencies: item 1
   - Validation: `ChatViewModelTests`
   - Linear update: yes

4. Replace event demo behavior with honest runtime state
   - Why it matters: event mode is a headline feature and must not masquerade as live when data is missing
   - Root cause: view-local sample data and always-on assumptions
   - Affected systems: `EventView`, `EventViewModel`, location/geofence startup
   - Fix strategy: drive from injected view model, show empty/error/sync state, keep tab visible but truthful
   - Dependencies: item 1
   - Validation: native build and source inspection
   - Linear update: yes

### C. Security / trust / data integrity

5. Make profile/settings/store/account surfaces fail honest
   - Why it matters: user trust is damaged by unsupported recovery/export/delete/verification flows presented as live
   - Root cause: UI shipped ahead of backend/runtime wiring
   - Affected systems: `ProfileView`, `SettingsView`, `VerifiedProfileSheet`, `MessagePackStore`
   - Fix strategy: route through real profile view model, disable unsupported actions, present accurate copy
   - Dependencies: item 1
   - Validation: native build
   - Linear update: yes

6. Align docs with actual privacy posture
   - Why it matters: release readiness cannot be judged correctly while README overclaims E2E encryption
   - Root cause: docs remained aspirational while app integration stayed partial
   - Affected systems: `README.md`
   - Fix strategy: describe packet signing as live and Noise confidentiality wiring as incomplete
   - Dependencies: none
   - Validation: diff review
   - Linear update: optional, but recommended in summary comment

### D. Reliability and observability gaps

7. Make sign-out clear identity and local state for real
   - Why it matters: stale local runtime/store state undermines every subsequent session
   - Root cause: onboarding flag reset without actual state teardown
   - Affected systems: `AppCoordinator`, profile/settings flow
   - Fix strategy: delete identity, clear local SwiftData models, reset onboarding state, stop transports/geofencing
   - Dependencies: item 1
   - Validation: native build and code inspection
   - Linear update: yes

### E. Architecture corrections

8. Seed and persist one preferences truth source
   - Why it matters: profile/settings behavior should survive app restarts and reflect one model
   - Root cause: mixed `AppStorage` defaults and SwiftData preferences
   - Affected systems: onboarding, profile VM, settings, coordinator bootstrap
   - Fix strategy: create `UserPreferences` when absent, bridge legacy defaults, write through profile VM bindings
   - Dependencies: item 1
   - Validation: native build
   - Linear update: optional

### F. Performance improvements

No dedicated performance changes were required for this batch. Performance remained secondary to trust and wiring defects.

### G. Test and CI hardening

9. Add regression coverage for DM-channel creation
   - Why it matters: protects the fixed persisted-user path from regressing
   - Root cause: no test guaranteed DM reuse and membership creation
   - Affected systems: `ChatViewModelTests`
   - Fix strategy: add creation/reuse tests
   - Dependencies: item 3
   - Validation: `BlipTests/ChatViewModelTests`
   - Linear update: no

### H. Maintainability / DX cleanup with leverage

10. Leave pre-existing package failures and Swift concurrency warnings explicitly deferred
   - Why it matters: avoids hiding baseline debt inside this PR while still documenting it
   - Root cause: existing main-branch debt outside the minimum safe remediation slice
   - Affected systems: `BlipMesh`, `BlipCrypto`, multiple native files using `nonisolated(unsafe)`
   - Fix strategy: document and follow up separately
   - Dependencies: none
   - Validation: baseline verification logs
   - Linear update: yes

## Immediate vs Structural Work Split

### Immediate work completed in this branch

- coordinator composition-root enforcement
- profile/settings/sign-out truthfulness and persistence
- event runtime honesty
- DM creation and chat regression tests
- auth worker input hardening and safer defaults
- README / verification-trust copy correction

### Structural work intentionally deferred

- full Noise encryption wiring into app message flows
- real backend receipt verification and verified-profile commerce completion
- package baseline cleanup for crypto/mesh failures
- Swift 6 concurrency warning cleanup
