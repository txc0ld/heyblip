# Implementation Plan

## Ordered Work Plan

1. Shared friend-finder runtime
   - Evidence: `FriendFinderViewModel` already existed but `FriendFinderMapView` still used sample state.
   - Why it matters: Nearby/location UX looked more capable than the actual full-screen map.
   - Fix: add coordinator-owned `FriendFinderViewModel`, stabilize peer pin IDs, and wire the full-screen map to shared location + beacon state.
   - Validation: app build, manual source review of injected paths.

2. Nearby navigation and state clarity
   - Evidence: `NearbyView` exposed inline map state but did not deliberately route users into the strongest map surface.
   - Why it matters: primary discovery flow felt fragmented.
   - Fix: add explicit “Open Full Map” navigation and keep inline status cards tied to real conditions.
   - Validation: build, source walk of `NearbyView` navigation path.

3. Public/safety surface trust corrections
   - Evidence: `LostAndFoundView` and earlier `MedicalDashboardView` behavior implied live shared/safety workflows without real wiring.
   - Why it matters: very high trust impact.
   - Fix: keep screens discoverable but convert them to honest unavailable/readiness states.
   - Validation: build, copy review for no false-success or fake-post behavior.

4. Store model ownership cleanup
   - Evidence: `ProfileView` already passed a shared store model, but sheet-level store surfaces could still instantiate their own.
   - Why it matters: split purchase/loading state degrades perceived reliability.
   - Fix: resolve to injected `StoreViewModel` when provided and only create a local fallback when needed.
   - Validation: build, source review of `MessagePackStore` and `PaywallSheet`.

## Deferred

- Real festival public-channel posting
- Responder authentication and live medical dashboard
- Real-device location + mesh UX validation
- Broad Swift 6 warning cleanup
