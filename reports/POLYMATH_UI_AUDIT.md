# Polymath UI Audit

## Surface Audit

### Nearby

- Visual issue: map controls and inline preview competed with people/friends/channel sections for attention.
- Interaction issue: the stronger friend-finder surface was not promoted clearly from the Nearby tab.
- Functional issue: live friend-finder behavior and demo map behavior were split across different screens and models.
- State-quality issue: empty map conditions needed clearer explanations tied to permission and sharing state.
- Evidence: `Sources/Views/Tabs/NearbyTab/NearbyView.swift`, `Sources/Views/Tabs/NearbyTab/FriendFinderMapView.swift`

### Friend Finder

- Visual issue: control stack was noisy and included crowd controls unsupported by real runtime data.
- Interaction issue: location sharing, empty state, and beacon affordances were not clearly staged around availability.
- Functional issue: the view still relied on sample friends/beacons when opened without live integration.
- Reliability issue: live peer pins needed stable identity so map selection and updates did not churn.
- Evidence: `Sources/Views/Tabs/NearbyTab/FriendFinderMapView.swift`, `Sources/ViewModels/FriendFinderViewModel.swift`

### Event Utility Surfaces

- Lost & Found issue: screen presented itself like a live public board while only appending local state.
- Medical issue: a client-only unlock path exposed fake responder capability and sample incidents in a safety-critical surface.
- Trust impact: high.
- Evidence: `Sources/Views/Tabs/EventsTab/LostAndFoundView.swift`, `Sources/Views/Tabs/EventsTab/MedicalDashboard/MedicalDashboardView.swift`

### Store / Paywall

- Visual issue: paywall and store were close in style but risked diverging state if each built its own model.
- Functional issue: duplicate `StoreViewModel` ownership could split loading, purchase, and restore state across sheets.
- Backend abstraction issue: catalog failure needed an honest unavailable state, not a presentational fallback that looked buyable.
- Evidence: `Sources/Views/Tabs/ProfileTab/MessagePackStore.swift`, `Sources/Views/Shared/PaywallSheet.swift`

### Profile / Action Sheets

- Interaction issue: the profile sheet could present action space larger than the actually supplied handlers.
- UX architecture issue: optional actions needed to collapse cleanly instead of leaving dead or implied controls.
- Evidence: `Sources/Views/Shared/ProfileSheet.swift`

### SOS

- Functional issue: SOS confirmation needed to stay coupled to `SOSViewModel` so the UI reflects actual flow state and error handling.
- Reliability issue: emergency UI cannot rely on appearance-only confirmation.
- Evidence: `Sources/Views/Shared/SOSButton.swift`, `Sources/Views/Shared/SOSConfirmationSheet.swift`

## Accessibility Issues

- Unavailable features needed explicit descriptive text rather than only disabled styling.
- Map/location states needed concise banners describing why the view was empty.
- Optional action groups needed to shrink instead of preserving empty button rows.

## Performance-as-UX Issues

- Store and paywall model duplication risked extra StoreKit startup work and inconsistent perceived state.
- Friend-finder selection instability risked visible map churn when pins rebuilt.

## Institutional-Quality Gaps

- Safety-critical and public-channel surfaces were previously the biggest trust violations because they looked live while not being live.
- Some user-facing flows still depend on device/simulator/runtime conditions outside the UI layer, especially simulator-backed XCTest and real-device mesh/location behavior.
