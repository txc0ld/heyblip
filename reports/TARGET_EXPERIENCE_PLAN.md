# Target Experience Plan

## Target UX Principles

- Show capability clearly, but never imply backend readiness that does not exist.
- Make empty states instructional, not apologetic.
- Keep premium visuals, but let hierarchy and outcome clarity do the work instead of extra controls.

## Target Visual Principles

- Fewer competing chips/buttons in each header row.
- One primary action per cluster.
- Consistent glass-card status treatment for loading, unavailable, and empty states.

## Target Flow Principles

- Nearby should lead naturally into the full friend-finder map.
- Store and paywall should feel like one purchase system, not parallel sheets with separate state.
- Festival utility surfaces should be discoverable without pretending to be live.

## Intended Backend Abstraction Approach

- If runtime support exists, wire the shared model directly.
- If runtime support does not exist, replace simulated success with honest readiness messaging.
- Never surface sample incidents/messages as operational truth.

## Implementation Priorities

1. Nearby / Friend Finder coherence
2. trust-critical feature honesty in Medical and Lost & Found
3. single-source-of-truth store ownership
4. cleanup of optional action affordances in profile/sheets
5. verification and report refresh
