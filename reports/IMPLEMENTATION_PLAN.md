# Implementation Plan

## Ordered Work Plan

1. Reuse coordinator-owned store and location view models across entry points.
   - Evidence: duplicated or private surface state kept drifting from app truth.
   - Files: `Sources/Services/AppCoordinator.swift`, `Sources/Views/Tabs/MainTabView.swift`, `Sources/Views/Tabs/ProfileTab/ProfileView.swift`, `Sources/Views/Tabs/ChatsTab/ChatView.swift`
   - Validation: build, store/paywall manual-path inspection by code, shared state refresh on dismiss.

2. Replace simulated paywall purchase flow with the real store stack.
   - Evidence: `PaywallSheet` used a timer-based fake success path.
   - Files: `Sources/Views/Shared/PaywallSheet.swift`, `Sources/ViewModels/StoreViewModel.swift`
   - Validation: build, runtime-path inspection, success/error/restore wiring review.

3. Remove misleading store fallback inventory.
   - Evidence: static product cards rendered even when App Store loading failed.
   - Files: `Sources/Views/Tabs/ProfileTab/MessagePackStore.swift`
   - Validation: build, empty/error state review.

4. Make Nearby/Friend Finder depend on real location-sharing state.
   - Evidence: friend pins were created from fabricated coordinates instead of shared friend-location data.
   - Files: `Sources/Views/Tabs/NearbyTab/NearbyView.swift`, `Sources/ViewModels/LocationViewModel.swift`, `Sources/ViewModels/FriendFinderViewModel.swift`, `Sources/Views/Tabs/NearbyTab/FriendFinderMapView.swift`
   - Validation: build, state-path inspection for no-permission/no-shared-location/shared-location cases.

5. Convert unfinished festival adjuncts to honest unavailable states.
   - Evidence: local-only Lost & Found posting and fake medical unlock/demo responder data.
   - Files: `Sources/Views/Tabs/FestivalTab/LostAndFoundView.swift`, `Sources/Views/Tabs/FestivalTab/MedicalDashboard/MedicalDashboardView.swift`
   - Validation: build, view-state inspection.

## Dependencies

- Shared coordinator injection needed first so paywall/store/profile/chat use consistent state.
- Store model hardening needed before paywall and profile store cleanup.
- Location view-model refresh helpers needed before Nearby/Friend Finder map cleanup.

## Rationale

- These fixes remove the largest remaining trust gaps without redesigning stable surfaces.
- They reduce product-risky illusion while preserving the app’s existing visual language.
