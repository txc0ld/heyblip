# UI / UX Recon

## Current Product Experience

Blip is a mesh-first festival communication app. The primary user jobs exposed in the app are:

- discover nearby people and friends
- start and continue direct conversations
- understand whether festival-specific features are available on the current device
- manage identity, balance, and emergency actions without reading transport details

The visual shell is already stronger than the underlying runtime truth in several places. The recurring experience problem was not lack of UI effort, but screens that looked finished while still relying on private state, sample content, or incomplete backend wiring.

## Key User Journeys

1. Nearby discovery
   - User expects peer count, nearby people, nearby friends, and map visibility to reflect live mesh state.
   - Evidence: `Sources/Views/Tabs/NearbyTab/NearbyView.swift`, `Sources/ViewModels/MeshViewModel.swift`
2. Friend location and beacon sharing
   - User expects location sharing and the friend finder map to represent actual shared coordinates or explain clearly why the map is empty.
   - Evidence: `Sources/Views/Tabs/NearbyTab/FriendFinderMapView.swift`, `Sources/ViewModels/FriendFinderViewModel.swift`, `Sources/ViewModels/LocationViewModel.swift`
3. Festival companion workflows
   - User expects lost-and-found and medical surfaces to be trustworthy, especially because they imply public coordination and safety response.
   - Evidence: `Sources/Views/Tabs/FestivalTab/LostAndFoundView.swift`, `Sources/Views/Tabs/FestivalTab/MedicalDashboard/MedicalDashboardView.swift`
4. Monetization and message recovery
   - User expects message pack and paywall flows to use real StoreKit data, or to fail honestly when catalog and entitlements are unavailable.
   - Evidence: `Sources/Views/Tabs/ProfileTab/MessagePackStore.swift`, `Sources/Views/Shared/PaywallSheet.swift`, `Sources/ViewModels/StoreViewModel.swift`
5. Emergency SOS
   - User expects the SOS flow to use real state progression, not a detached UI-only confirmation flow.
   - Evidence: `Sources/Views/Shared/SOSButton.swift`, `Sources/Views/Shared/SOSConfirmationSheet.swift`, `Sources/ViewModels/SOSViewModel.swift`

## Pain Points Found

- The full-screen friend finder view was still demo-oriented even though live location packet plumbing existed elsewhere.
- Nearby exposed map affordances, but the strongest friend-finder surface was not reachable from the tab in a deliberate way.
- Lost & Found and Medical Dashboard previously implied live shared/public functionality that was not actually wired end to end.
- Store and paywall surfaces had already improved, but the view-model ownership still risked duplicate state and duplicated StoreKit listeners.
- Some profile-sheet actions existed visually even when no handler existed, which increased affordance noise.

## Design Inconsistencies

- Nearby mixed live mesh status with map affordances that previously depended on separate, weaker data sources.
- Some unavailable features used active CTAs; others used copy-only disclaimers. This pass standardized toward honest inactive states or real wiring.
- Secondary action density in `ProfileSheet` was high relative to actual available behavior.

## Functional Integrity Concerns

- Safety and responder UI cannot use fabricated sample incidents without undermining trust.
- Public-channel UI cannot post device-local messages while presenting itself as a shared board.
- Location/friend-finder UI must not show fabricated map overlays or static crowd representations as live state.

## Backend Leakage Observations

- Prior responder access depended on a client-only unlock pattern, which exposed implementation weakness directly in the safety workflow.
- Store/catalog failures surfaced as “missing product” situations that needed clearer outcome-oriented messaging.
- The friend-finder map previously leaked unfinished implementation status through sample data rather than explicit readiness states.
