# Specialist Agent Findings

## Product Experience Architect

- Prioritize trust over density. The biggest user-experience failures were not navigation problems; they were believable but incomplete flows.
- Nearby, Store, and Festival adjuncts should communicate availability honestly instead of preserving pretty placeholders.

## Visual Systems Director

- The visual language was already coherent enough to support refinement without redesign.
- Highest-value visual improvement was pairing existing polished cards with better explanatory states, not changing the design system.

## Interaction Design Agent

- Paywall interaction was the most misleading flow because the CTA succeeded locally without StoreKit truth.
- Secondary interactions improved when unavailable paths were turned into explicit information instead of soft-dead buttons or fake completion.

## Frontend Craftsmanship Agent

- Shared coordinator-owned view models reduce drift and duplicated runtime state.
- Nearby/Friend Finder and Store surfaces benefited from being supplied with real runtime models rather than rebuilding private UI-only state.

## Backend Integration Integrity Agent

- `PaywallSheet` needed to consume `StoreViewModel`.
- `MessagePackStore` needed to stop using static catalog fallback.
- Lost & Found and Medical needed honest degradation because their backend/data paths are not production-backed.

## State, Data, and Sync Agent

- Location-driven UI needed to distinguish:
  - mesh presence
  - device location availability
  - shared friend-location availability
- Store state needed one source of truth for product loading, purchase, restore, and balance refresh.

## Functional Correctness Agent

- Fake medical unlock and simulated paywall purchase were the highest-severity visible correctness issues.
- Nearby map trust was weaker than nearby peer-card trust because the former used fabricated spatial context.

## Accessibility and Usability Agent

- Honest banners and unavailable explanations were preferable to interactive dead ends.
- The revised states improved comprehension without adding visual clutter.

## Reliability and Trust Agent

- Trust failures were caused by false-success UI, not by loud error states.
- The correction strategy was:
  - real runtime data when available
  - explicit retry states on fetch failure
  - disabled/informational states where functionality is not truly live

## Design-to-Code Consistency Agent

- The design language already communicated premium quality; the implementation gaps were undermining that promise.
- This pass mainly improved consistency between what the UI suggests and what the code actually does.

## Overlaps

- All specialist lenses converged on the same root cause:
  the remaining UX debt was mostly integrity debt.

## Conflicts

- One tension remained: whether to hide unfinished surfaces entirely or keep them visible with honest degradation.
- This pass chose honest degradation for discoverability on Festival utility surfaces and for continuity on store/paywall entry.

## Orchestrated Synthesis

- Fix truthfulness first.
- Reuse shared runtime view models wherever practical.
- Preserve the existing visual system.
- Prefer calm explanatory states over fake activity, fake success, or fake data.
