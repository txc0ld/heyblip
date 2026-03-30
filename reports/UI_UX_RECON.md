# UI / UX Recon

## Product Experience Read

Blip is trying to feel like a calm, premium festival coordination app on top of unstable transport and partial backend capability. The user-facing jobs are:

- discover nearby people and friends
- start a DM quickly
- understand whether the mesh is healthy
- locate friends or rendezvous points without thinking about transport layers
- manage identity, preferences, and paid message balance without confusion

## Key Journeys Audited

1. Nearby discovery -> open peer profile -> add friend
2. Low-balance chat send -> paywall -> purchase/top-up
3. Profile -> message packs / verified profile / settings
4. Festival surfaces -> medical responder access

## Evidence-Based Pain Points

- `Sources/Views/Shared/PaywallSheet.swift`
  The sheet previously simulated successful purchases locally and told the user their message would send immediately after purchase. That was false-success behavior on a monetized path.
- `Sources/Views/Tabs/ProfileTab/MessagePackStore.swift`
  The store fell back to static purchasable-looking cards when StoreKit failed to load. That preserved a premium surface while disconnecting it from reality.
- `Sources/Views/Shared/ProfileSheet.swift`
  The shared profile sheet always rendered Message / Block / Report actions even when no handlers were provided, creating dead controls across Nearby and Friends surfaces.
- `Sources/Views/Tabs/FestivalTab/MedicalDashboard/MedicalDashboardView.swift`
  The previous responder dashboard unlocked fabricated alerts and map data after any 4-character code. That was a critical trust break on an emergency surface.
- `Sources/Views/Tabs/NearbyTab/NearbyView.swift`
  The map/help states needed to communicate the difference between nearby mesh peers and opt-in location-sharing friends so the UI did not imply the map was “broken” when GPS sharing simply was not present.

## Design / Hierarchy Issues

- Purchase flows had multiple surfaces with different truth levels: real store in Profile, simulated store in Chat paywall.
- Unavailable capabilities were presented as interactive buttons instead of informative status states.
- Trust-critical messaging was too implementation-naive: the UI described optimistic outcomes instead of confirmed ones.
- Emergency UX was visually polished but operationally fake, which is worse than an explicit unavailable state.

## Functional Integrity Concerns

- Paywall success was not coupled to App Store confirmation.
- Store fallback catalog encouraged taps on products that did not exist for the current device session.
- Profile actions were visually primary even when unsupported by the caller.
- Medical responder auth and live incident sync were absent, but the UI implied otherwise.

## Backend / System Leakage

- StoreKit failure was hidden behind a fake local catalog instead of surfaced as “store unavailable.”
- Emergency responder access used a client-only affordance rather than admitting the organizer auth backend was missing.
- Nearby location-sharing state needed clearer explanation so users understood why mesh discovery and map visibility can diverge.
