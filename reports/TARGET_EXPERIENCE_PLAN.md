# Target Experience Plan

## Target UX Principles

- Every visible control should either work against a real backing system or clearly explain why it is unavailable.
- Shared runtime state should drive the UI across entry points.
- Empty states should describe what is missing, not just that “nothing is here.”

## Target Visual Principles

- Preserve the existing glass/gradient design language.
- Use explanatory cards and compact banners to clarify state instead of adding new chrome.
- Keep density low and hierarchy stable.

## Target Flow Principles

- Chat purchase flow:
  - real StoreKit-backed purchase
  - real balance refresh
  - no promise of automatic message resend
- Nearby/Friend Finder:
  - mesh presence and GPS sharing are separate concepts
  - map only reflects actual shared location state
- Festival adjunct utilities:
  - unfinished shared/public functionality should fail honest

## Intended Backend Abstraction Approach

- Hide backend/process complexity, but never hide the absence of backend wiring.
- Translate missing capability into user-facing outcomes:
  - unavailable
  - retry
  - waiting for shared data
  - needs permission

## Implementation Priorities

1. Replace fake purchase behavior with real store-backed behavior.
2. Remove catalog fallback that looks like real inventory.
3. Make Nearby/Friend Finder map semantics truthful.
4. Disable fake public/emergency flows while keeping discovery and product structure intact.
