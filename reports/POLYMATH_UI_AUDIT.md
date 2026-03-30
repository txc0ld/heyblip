# Polymath UI Audit

## Audit By Surface

### Nearby

- Visual: strong hierarchy, but the Friend Finder section implied spatial accuracy it did not have.
- Interaction: `Show Map` exposed a plausible map even when only mesh-presence data existed.
- Functional: `Sources/Views/Tabs/NearbyTab/NearbyView.swift` mapped nearby friends to fabricated coordinates.
- State quality: empty/loading logic did not distinguish “no mesh peers” from “no shared GPS locations”.
- Accessibility/usability: visibility and map affordances were understandable, but the map explanation layer was missing.

### Chat + Paywall

- Visual: paywall presentation was coherent.
- Interaction: low-balance action path was clear.
- Functional: `Sources/Views/Shared/PaywallSheet.swift` simulated purchase success rather than using `StoreViewModel`.
- State quality: copy promised immediate continuation even though the message send was not retried automatically.
- Trust gap: purchase outcome and balance state could diverge from reality.

### Profile Store

- Visual: cards and balance hierarchy were strong.
- Functional: `Sources/Views/Tabs/ProfileTab/MessagePackStore.swift` previously rendered fallback static packs on product-load failure.
- Reliability: users could interpret catalog failure as successful product availability.
- Institutional gap: product surfaces should not fabricate commercial inventory.

### Festival Utility Surfaces

- Lost & Found:
  - Visual: credible public-channel shell.
  - Functional: local-only/sample messaging in `Sources/Views/Tabs/FestivalTab/LostAndFoundView.swift`.
  - Trust gap: implied shared/public functionality without actual shared transport.
- Medical Dashboard:
  - Visual: polished responder dashboard shell.
  - Functional: fake local unlock and sample responder state in `Sources/Views/Tabs/FestivalTab/MedicalDashboard/MedicalDashboardView.swift`.
  - Trust gap: institutional-looking emergency tooling cannot be demo-unlocked in a live build.

## Issue Classes

- Simulated transactional UX
- Fallback catalogs masquerading as real products
- Placeholder map semantics
- Demo emergency tooling
- Public-channel shells without shared persistence

## Accessibility / Usability

- Positive:
  - touch targets remain generally strong
  - glass-card layouts maintain readable grouping
  - major controls are labeled
- Remaining issues:
  - some unavailable states still rely on explanatory copy rather than route-level hiding
  - there is still limited assisted guidance for “what happens after purchase” in chat

## Performance As UX

- This pass did not uncover a major rendering bottleneck more important than integrity work.
- The more important UX-performance issue was perceived latency under uncertainty:
  - store catalog loading without honest retry states
  - map surfaces showing fabricated results rather than empty live state

## Institutional-Quality Gaps

- Not all product-adjacent surfaces are production-truthful yet.
- Real device/location/store behaviors are materially better surfaced after this pass, but the app still has deferred work around:
  - full private-message confidentiality
  - real shared Lost & Found transport/persistence
  - real responder authentication/data feeds
