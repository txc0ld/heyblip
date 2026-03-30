# Target Experience Plan

## Target UX Principles

- Every visible primary action must have a real outcome.
- Unavailable capabilities should read as intentional status states, not broken controls.
- Recovery paths should be explicit: retry, go back, or wait for confirmation.

## Target Visual Principles

- Premium surfaces remain premium even when the answer is “not available.”
- Status cards should be calm and legible, not punitive or noisy.
- Monetization and safety surfaces must use the clearest possible hierarchy.

## Target Flow Principles

- Chat top-up: select real product -> purchase -> return to chat -> resend.
- Store catalog: load real products or show unavailable/retry.
- Peer profile: show only supported actions.
- Medical dashboard: expose build readiness honestly until auth + live data exist.

## Backend Abstraction Approach

- Hide StoreKit/backend failure behind a clear user-facing store state, not fake products.
- Hide emergency-system absence behind an unavailable readiness screen, not sample incidents.
- Keep transport/location complexity out of primary user copy unless it affects the current outcome.

## Implementation Priorities

1. Remove false-success purchase UX.
2. Remove fake emergency access.
3. Remove dead shared actions.
4. Improve nearby/map availability communication.
