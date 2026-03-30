# Implementation Plan

## Ordered Work

1. Replace simulated chat paywall purchase flow
   Evidence: `PaywallSheet` previously used local timers and success flags instead of `StoreViewModel`.
   Why it matters: monetization and message-balance trust.
   Fix: bind the sheet to `StoreViewModel`, live products, restore, and real success/error messaging.
   Validation: app build plus manual code-path inspection.

2. Remove fake fallback catalog from the main message store
   Evidence: `MessagePackStore` rendered static product cards whenever StoreKit failed.
   Why it matters: visual polish was masking unavailability.
   Fix: replace fallback cards with unavailable/retry state; remove dead subscription CTA.
   Validation: app build and surface audit.

3. Remove dead shared profile actions
   Evidence: `ProfileSheet` rendered Message / Block / Report even with nil handlers.
   Why it matters: repeated UX lie across multiple tabs.
   Fix: action-row becomes capability-driven.
   Validation: build and caller review.

4. Replace fake medical responder flow with honest readiness state
   Evidence: any 4-character code unlocked sample emergencies.
   Why it matters: safety-trust and institutional credibility.
   Fix: disable fake workflow, explain missing organizer auth + live responder sync requirements.
   Validation: build and code-path inspection.

5. Keep Nearby map-state messaging aligned with real runtime availability
   Evidence: map value depends on location fix and opt-in friend sharing, not only mesh presence.
   Why it matters: avoids “map is broken” interpretation.
   Fix: preserve and document status-card communication around missing location / shared pins.
   Validation: build and surface audit.
