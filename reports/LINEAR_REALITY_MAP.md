# Linear Reality Map

## Workspace Snapshot

- Team: `FezChat`
- Active project signal: `Sprint 2`
- Visible cycle structure: no active/current/next cycles configured
- Dominant labels visible in workspace: `Infra`, `Protocol`, plus feature-area labels from the issue stream
- Human contributors visible in workspace: two active users

## What Linear Says The Product Is

Blip/FezChat is intended to be a BLE-first event communication app with:

- mesh DMs and group messaging
- nearby discovery and friend management
- event-mode map, schedule, announcements, and crowd pulse
- medical/SOS responder workflows
- message-pack monetization and verified-profile upsell
- real-device resilience when towers are saturated or absent

The strongest product signal is not "social chat app." It is "event coordination app that must remain useful when infrastructure fails."

## Product Intent Model

### Core user journeys

1. Onboard, verify identity, and enter the app with a stable local profile.
2. Discover nearby peers over BLE, add friends, and open a DM thread.
3. Use event mode for map/schedule/announcements once a manifest or geofence is available.
4. Trigger urgent SOS / medical responder flows with reliable packet delivery.
5. Buy message packs or verified status without undermining user trust.

### Product promises implied by Linear

- BLE advertising and discovery must work on real devices, not just simulator/test doubles.
- Nearby and DM flows must behave live, not as mock/demo shells.
- Mesh routing, signing, and relay correctness are product-critical infrastructure, not background technical debt.
- Message transport trust guarantees matter because the product narrative depends on privacy and reliability.

## Delivery Reality Model

Recent Linear activity shows rapid stacked delivery, with several tickets already linked to merged or ready PRs:

- `FEZ-69`: BLE advertising not starting
- `FEZ-70`: gossip relay wired into production
- `FEZ-71`: Ed25519 packet signing layer
- `FEZ-72`: RSSI, disconnects, friend lifecycle, UX cleanup

Open / still-relevant tickets point to the remaining quality gap:

- `FEZ-68`: Nearby peer cards and DM-over-BLE end-to-end flow still broken/drifting
- `FEZ-52`: real-device two-phone mesh validation still required
- `FEZ-61`: Swift 6 concurrency cleanup outstanding
- `FEZ-17`: medical dashboard remains high-priority product work

Linear comments also indicate a pattern of "top 12 fixed" / "PR ready" notes that consolidate many issues into branch-local remediation batches. That is useful velocity, but it also increases risk that repo/main and ticket reality drift apart.

## Priority Areas

### Highest product-risk areas

1. BLE discovery, advertising, and DM routing on physical devices
2. session / identity / friend lifecycle correctness
3. transport trust guarantees versus app and docs claims
4. event mode live-data activation instead of sample/demo state
5. StoreKit / verification surfaces that can mislead users

### Secondary but material areas

1. Swift 6 concurrency warnings that will harden into errors
2. responder / medical workflow completion
3. release safety around stacked PRs and unverified branch-local fixes

## Issue Density Zones

Linear clusters issues most heavily around:

- BLE advertising and peer discovery
- DM creation and nearby-peer rendering
- routing / relay / signing infrastructure
- signal strength / peer lifecycle UX
- real-device validation

That clustering strongly suggests shared root causes in composition, transport integration, and truthfulness of feature state.

## Repeated Pain Points

- Features appear implemented in tickets before they are stable end-to-end on `main`.
- Real-device validation trails code merges.
- Trust/security features are partly implemented at the package level but incompletely integrated at the app level.
- UI/UX tickets repeatedly mask dependency-injection and runtime wiring problems underneath.

## Risk Heatmap

| Area | Heat | Why |
|---|---:|---|
| BLE discovery + DM flow | 5 | Open tickets, real-device blocker, direct user-journey breakage |
| Transport trust/security | 5 | Product/docs claim strong privacy while app wiring is incomplete |
| Event-mode activation | 4 | Feature breadth exists, but runtime truth vs sample state drifts |
| Profile/settings/store trust | 4 | Unsupported actions and fake commerce affordances damage trust |
| Release safety / stacked branches | 4 | Linear comments reference PR chains and branch-local readiness |
| Swift 6 readiness | 3 | Not an immediate outage, but warnings are systemic debt |

## Priority Matrix

### Must fix now

- composition-root drift that leaves tabs on private/demo state
- fake or unsupported user actions that claim live account/verification behavior
- auth-worker trust bugs that accept privileged client fields or ship with dev bypass enabled
- documentation and user-facing trust copy that overstates security guarantees

### Must investigate next

- true Noise encryption wiring for private messaging
- real-device BLE validation across two phones
- concurrency cleanup before Swift 6 hard-errors

### Can follow after core stabilization

- deeper performance tuning
- broader CI pipeline hardening
- medical dashboard completion once transport truth is stable

## Contradictions / Ambiguities

- Linear suggests private messaging and signing are actively being fixed, but does not guarantee that private-message confidentiality is truly wired end-to-end on `main`.
- Some issues/comments describe work as "ready" or "done" while open tickets still indicate broken adjacent flows.
- Product messaging implies production-like encryption and verification, but ticket history suggests these systems remain partially integrated.

## Linear-to-Code Audit Checklist

- Verify the coordinator is the real composition root.
- Verify nearby discovery cards reflect live peer data.
- Verify DM creation uses persisted users and real message transport.
- Verify sign-out resets identity and local state rather than only toggling `AppStorage`.
- Verify event mode uses fetched/cached manifests and geofence state, not permanent sample data.
- Verify verified-profile and account-management affordances are honest.
- Verify backend auth endpoints do not accept client-controlled privilege escalation.
- Verify README / docs match current implementation reality.
