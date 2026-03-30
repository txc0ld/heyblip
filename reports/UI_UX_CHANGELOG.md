# UI / UX Changelog

## What Changed

- `PaywallSheet` now uses the real `StoreViewModel` and App Store product state instead of a simulated timer-based purchase flow.
- Chat now opens the paywall with the coordinator-owned store model and refreshes profile balance on dismiss.
- Profile store now reuses shared store state and shows retry/unavailable messaging instead of static fake catalog cards.
- Nearby now uses real location-sharing state for Friend Finder context and explains permission/no-shared-location cases explicitly.
- Friend Finder support code now stabilizes peer IDs and supports one-shot location refresh for display.
- Lost & Found no longer pretends to post to a shared public channel when that channel is not wired.
- Medical Dashboard no longer unlocks off a fake local code or show demo responder data as if live.
- `ProfileSheet` secondary-action model was normalized to current `GlassButton.Style` usage to keep the build green on the current toolchain.

## Why It Changed

- The app’s main remaining UX weakness was believable but incomplete behavior.
- This pass prioritized operational trustworthiness over new visual styling.

## Issues Resolved

- False-success purchase UX
- Fake/fallback store inventory
- Fabricated map context in Nearby/Friend Finder
- Demo emergency/public-channel flows presented as live
- Shared-state drift between chat/profile/store entry points

## Deferred

- Real shared/public Lost & Found transport
- Organizer-authenticated medical responder workflow
- Full real-device validation of Friend Finder/live location behavior
