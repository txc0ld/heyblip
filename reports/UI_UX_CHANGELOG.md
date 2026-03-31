# UI / UX Changelog

## What Changed

- Added a shared `FriendFinderViewModel` to `AppCoordinator` so the map flow can use runtime-owned live state.
- Stabilized friend-finder pin identity generation in `FriendFinderViewModel`.
- Promoted the full friend-finder map from `NearbyView` with an explicit navigation path.
- Reworked `FriendFinderMapView` to consume shared live state, remove fake crowd controls, and explain empty/location-dependent states clearly.
- Kept `LostAndFoundView` visible but honest: no fake public posting in this build.
- Kept `MedicalDashboardView` visible but honest: no local sample responder unlock or fabricated incidents.
- Kept store/paywall surfaces on real StoreKit-backed state and preferred shared `StoreViewModel` ownership where available.
- Tightened optional action rendering in `ProfileSheet`.
- Wired SOS entry surfaces to `SOSViewModel`-backed confirmation flow.

## Why It Changed

- The main remaining defect class was UI truth drift: polished screens were still outrunning backend/runtime completion.
- The branch needed stronger institutional trust, not more decorative polish.

## Issues Resolved

- Friend-finder full-screen experience no longer defaults to demo data in the shared app path.
- Nearby now routes users into the full friend-finder flow more clearly.
- Lost & Found no longer stores device-local fake posts as if they were public.
- Medical dashboard no longer pretends responder functionality exists when it does not.
- Store ownership is less likely to diverge across sheets.

## Intentionally Deferred

- Live lost-and-found channel sync
- Real responder authentication and alert routing
- Real-device validation of location-sharing and BLE friend-finder behavior
