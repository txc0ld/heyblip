# UI / UX Changelog

## What Changed

- `Sources/Views/Shared/PaywallSheet.swift`
  Replaced simulated purchase flow with the real `StoreViewModel`, live product selection, restore handling, and truthful purchase copy.
- `Sources/Views/Tabs/ProfileTab/MessagePackStore.swift`
  Removed the fake fallback catalog and replaced it with a real unavailable/retry state. Removed the dead subscription CTA.
- `Sources/Views/Shared/ProfileSheet.swift`
  Shared profile actions are now rendered only when the caller actually wires them.
- `Sources/Views/Tabs/FestivalTab/MedicalDashboard/MedicalDashboardView.swift`
  Replaced weak-code sample-data responder flow with an honest unavailable/readiness screen.

## Why It Changed

- To remove false-success behavior.
- To stop premium visuals from legitimizing non-functional features.
- To reduce user confusion and eliminate dead controls.
- To improve institutional trust on monetization and emergency surfaces.

## Issues Resolved

- Fake purchase success in chat paywall
- Fake store products on StoreKit failure
- Dead Message / Block / Report profile actions
- Fake medical dashboard unlock and sample emergency feed

## Intentionally Deferred

- Real server-backed receipt verification enforcement
- Live medical responder workflow
- Real-device BLE/location validation
- Broader Swift 6 warning cleanup
