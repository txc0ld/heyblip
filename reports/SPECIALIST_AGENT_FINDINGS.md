# Specialist Agent Findings

## Execution Note

Specialist-agent delegation was attempted for this pass, but the external spawn path was unreliable in-session. Findings below were completed as explicit local role-based passes using the same repo context rather than invented agent output.

## Product Experience Architect

- Chat top-up needed to reflect the real post-purchase behavior: buy, then return and resend.
- Emergency responder UI should fail honest, not mimic readiness.
- Unsupported actions should disappear instead of remaining “discoverable.”

## Visual Systems Director

- Availability states should still look first-class, not like error dumps.
- Store fallback cards were visually indistinguishable from live products and had to become a distinct unavailable card.

## Interaction Design Agent

- Profile action rows needed to be capability-driven.
- Paywall primary CTA needed to bind to a selected real product, not a local placeholder model.

## Frontend Craftsmanship Agent

- `PaywallSheet` and `MessagePackStore` duplicated product UI with different truth models.
- `MedicalDashboardView` carried too much fake state for a trust-critical surface.

## Backend Integration Integrity Agent

- Paywall/store surfaces now use `StoreViewModel` rather than simulated local purchase success.
- Medical dashboard still has no safe live backend path, so the correct implementation is an honest unavailable state.

## Accessibility and Usability Agent

- Dead buttons were removed from the focus path in `ProfileSheet`.
- Unavailable states now explain what the user can do next: retry store, go back to chat, or wait for organizer-backed access.

## Functional Correctness Agent

- Simulated purchases and fake emergency data were the two highest-severity user-facing correctness failures in this pass.

## Orchestrated Synthesis

Highest-leverage fix order:

1. eliminate false-success and fake-capability surfaces
2. collapse duplicate purchase truth models into the real store-backed path
3. hide unsupported controls
4. keep Nearby/Friend Finder honest about runtime availability
