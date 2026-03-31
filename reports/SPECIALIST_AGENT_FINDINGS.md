# Specialist Agent Findings

## Execution Note

Attempted role-based delegation for this follow-on pass, but the current session did not provide a reliable spawned-agent workflow. The specialist roles below were executed centrally as separate local review lenses against the same checked-out branch and source context.

## Product Experience Architect

- Promote the full friend-finder experience from Nearby instead of hiding it behind a weaker inline preview.
- Replace fake public/safety workflows with explicit readiness states when backend completion is absent.

## Visual Systems Director

- Reduce control noise in the friend-finder view by removing unsupported crowd controls.
- Keep premium glass treatment, but use fewer, clearer status surfaces with stronger hierarchy.

## Interaction Design Agent

- Make empty and unavailable states explain the next real condition: permission, friend sharing, organizer auth, or StoreKit availability.
- Remove implied actions when no handler or capability exists.

## Frontend Craftsmanship Agent

- Reuse coordinator-owned view models for store and friend-finder state instead of local duplicates.
- Stabilize map item identity for live pin updates.

## Backend Integration Integrity Agent

- `MedicalDashboardView` must not unlock sample incidents locally.
- `LostAndFoundView` must not append device-local posts while presenting itself as a shared public board.
- Store/paywall must prefer real catalog state and explicit retry.

## State, Data, and Sync Agent

- Friend-finder map state should derive from one live packet-aware model when available.
- Nearby should keep mesh truth and map truth adjacent, not contradictory.

## Accessibility and Usability Agent

- Use readable explanatory banners for unavailable/location-dependent states.
- Keep action groups compact and only present controls with reliable outcomes.

## Reliability and Trust Agent

- Emergency and responder surfaces are trust-sensitive; honest unavailable states are preferable to sample data.
- Simulator test harness instability should be reported separately from assertion failures.

## Orchestrated Synthesis

The dominant root cause was still UI truth drift: polished surfaces were outrunning the actual runtime contracts. The highest-leverage fixes were:

1. wire the full friend-finder view to shared live state
2. expose it cleanly from Nearby
3. collapse fake public/safety workflows into explicit readiness states
4. keep StoreKit ownership single-source-of-truth across sheets
