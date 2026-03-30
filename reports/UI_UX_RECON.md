# UI / UX Recon

## Current Product Experience

Blip already had a strong visual foundation: gradient backgrounds, glass cards, deliberate typography, and a modern tab structure. The remaining UX issues were mostly integrity issues rather than pure styling issues. Several surfaces looked polished but were still backed by sample data, simulated purchasing, or local-only state.

## Key User Journeys Reviewed

- Nearby discovery: peer visibility, nearby people, nearby friends, location-channel list, friend finder map
- Chat continuation: low-balance paywall entry from chat, purchase path, return to message flow
- Festival utility: festival map/schedule shell, Lost & Found, medical responder adjunct
- Profile/account: message balance, store entry, settings, verification affordances

## Pain Points

- The chat paywall still simulated purchases locally even though the app already had a real `StoreViewModel`.
- The profile store could fall back to static product cards, which looked real enough to imply purchasable inventory when the App Store catalog had actually failed.
- Nearby/Friend Finder mixed real mesh state with fabricated map context. Shared friend locations were represented by placeholder coordinates rather than actual location-sharing data.
- Lost & Found presented a public-channel interface but only appended local sample/local-only messages.
- Medical dashboard access could be unlocked by a fake local rule and demo responder data.

## Design Inconsistencies

- Some surfaces had already been converted to “honest unavailable” states, while others still preserved soft-fake UX.
- State messaging varied in quality: profile/settings were explicit about unavailable actions, but paywall/store and festival adjuncts still leaned on fallback/demo behavior.
- Nearby’s visual shell was strong, but map trust broke because the map semantics no longer matched the data behind it.

## Functional Integrity Concerns

- `Sources/Views/Shared/PaywallSheet.swift`: simulated purchase path diverged from the real store implementation.
- `Sources/Views/Tabs/ProfileTab/MessagePackStore.swift`: static card fallback made catalog failure look like available products.
- `Sources/Views/Tabs/NearbyTab/NearbyView.swift`: friend-map pins were derived from mesh presence, not actual shared friend locations.
- `Sources/Views/Tabs/FestivalTab/LostAndFoundView.swift`: public-channel UX existed without shared/public persistence.
- `Sources/Views/Tabs/FestivalTab/MedicalDashboard/MedicalDashboardView.swift`: access and dashboard state were demo-driven.

## Backend Leakage Observations

- The real backend complexity problem here was not overexposure of technical detail, but concealment of missing backend wiring. Users saw calm product surfaces that suggested capability the system did not actually provide.
- The strongest UX correction was to make availability explicit and outcome-oriented:
  - real App Store data when available
  - retry states when unavailable
  - disabled or informational states where server/transport backing does not yet exist
