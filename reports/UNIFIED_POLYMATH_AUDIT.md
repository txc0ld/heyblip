# Unified Polymath Audit

## Subsystem Scores

| Subsystem | Score | Notes |
|---|---:|---|
| Product alignment | 2 | broad feature intent exists, but multiple shipped surfaces drift from runtime truth |
| Feature completeness | 2 | many flows exist structurally, several remain incomplete or overclaimed |
| Functional correctness | 3 | core tests are decent, but composition drift caused real user-path breakage |
| UX integrity | 2 | some polished shells still masked demo/fallback behavior |
| Architecture quality | 3 | strong package boundaries, weak app-shell composition discipline |
| Maintainability | 3 | generally readable, but coordinator leakage and placeholder affordances hurt clarity |
| Security / trust | 2 | signing is real; confidentiality and purchase/verification claims drifted from implementation |
| Performance / efficiency | 3 | no immediate critical bottleneck found in remediated surfaces |
| Reliability | 3 | routing/test footprint is solid, real-device validation still lagging |
| Observability | 2 | logs exist, but fault visibility is uneven and user-facing honesty was weak |
| Test quality | 4 | strong overall footprint; some failures already present on main |
| CI / release safety | 2 | stacked-branch velocity and incomplete runtime validation increase release risk |
| Documentation integrity | 1 | README and deeper docs materially overstated encryption/completeness |
| Operational resilience | 2 | auth worker posture and real-device gaps lower confidence |

## Major Findings

### F1. App-shell composition drift left tabs on private/demo state

- Subsystem: app architecture / frontend / runtime composition
- Severity: High
- Likelihood: High
- Blast radius: Chats, event, profile, settings, sign-out, onboarding transitions
- Evidence:
  - `BlipApp` owned `AppCoordinator`, but `MainTabView` and downstream tabs were not consistently consuming coordinator-owned view models/services.
  - `ChatListView` could construct its own `MessageService` and `ChatViewModel`.
  - event/profile surfaces had parallel local state and fallbacks.
- Impact:
  - live transport wiring could be bypassed
  - tab state diverged from actual app runtime state
  - sign-out and onboarding state became unreliable
- Suspected root cause: coordinator existed conceptually, but not as the enforced composition root
- Recommended fix direction: inject coordinator-owned feature view models into the tab shell and treat sign-out/bootstrap as coordinator responsibilities
- Validation method: native build, chat view-model tests, code-path inspection
- Dependency notes: prerequisite for stabilizing most user-visible flows

### F2. Event/profile/settings surfaces presented unsupported behavior as live

- Subsystem: UX integrity / product alignment
- Severity: High
- Likelihood: High
- Blast radius: Event tab, verified-profile purchase, account actions, settings persistence
- Evidence:
  - event tab previously fell back to sample/runtime-static state
  - verified-profile purchase previously mutated local state without real StoreKit/server verification
  - export/delete/recovery actions were placeholder affordances
  - settings mixed `AppStorage` and SwiftData truth sources
- Impact:
  - user trust damage
  - incorrect expectations around safety/privacy/account recovery
  - inconsistent app state across restarts
- Suspected root cause: polished UI shells shipped ahead of real backend/runtime integration
- Recommended fix direction: persist one preference source of truth, make unsupported actions visibly unavailable, and only present live event state when it exists
- Validation method: native build, manual source inspection of runtime paths
- Dependency notes: coupled to F1 because injected view models are needed for real state

### F3. Auth worker trusted client-controlled privilege fields and shipped with dev bypass enabled

- Subsystem: backend / security / trust
- Severity: Critical
- Likelihood: Medium
- Blast radius: registration, sync, receipt verification, production auth posture
- Evidence:
  - registration/sync accepted fields such as `isVerified` and `messageBalance`
  - `DEV_BYPASS` defaulted to `true` in `wrangler.toml`
  - receipt verification endpoint returned success semantics without real server validation guarantees
- Impact:
  - privilege escalation risk
  - fake verification/message-credit state
  - production misconfiguration risk
- Suspected root cause: development shortcuts were left on the trust boundary
- Recommended fix direction: sanitize bodies, reject privileged client fields, default bypass off, fail receipt verification closed when not configured
- Validation method: `server/auth` Vitest suite
- Dependency notes: independent of native app composition, but required for trustworthy commerce/profile surfaces

### F4. Public docs and product copy overstated encryption guarantees

- Subsystem: documentation integrity / security / product trust
- Severity: High
- Likelihood: High
- Blast radius: user trust, stakeholder understanding, release readiness
- Evidence:
  - README claimed all messages were end-to-end encrypted
  - `MessageService` still sends private-message payloads in plaintext inside `.noiseEncrypted` packet types
  - `docs/PROJECT-STATUS.md` already hinted that decryption/display integration was incomplete
- Impact:
  - false confidence for users and reviewers
  - misaligned prioritization if stakeholders believe confidentiality is already solved
- Suspected root cause: crypto package maturity exceeded app integration maturity, while docs remained aspirational
- Recommended fix direction: update user-facing copy to reflect current truth and treat full Noise wiring as deferred critical work
- Validation method: source inspection and README diff
- Dependency notes: does not solve confidentiality itself; it prevents misleading release posture

### F5. Native verification is strong overall, but main still carries pre-existing failures and concurrency debt

- Subsystem: QA / release safety / maintainability
- Severity: Medium
- Likelihood: High
- Blast radius: future delivery velocity, Swift 6 migration, regression confidence
- Evidence:
  - `BlipProtocol` tests pass
  - native `BlipTests` XCTest suites pass
  - `Packages/BlipMesh` still fails `GossipMultiHopTests` TTL expectation
  - earlier baseline `Packages/BlipCrypto` run failed `Noise XX Handshake Validation - T22`
  - build emits broad `nonisolated(unsafe)` and sendability warnings
- Impact:
  - non-green package baseline
  - migration friction
  - ambiguity about which failures belong to this PR versus existing debt
- Suspected root cause: high delivery velocity plus unfinished concurrency cleanup and some flaky/incorrect test expectations on main
- Recommended fix direction: explicitly separate remediated scope from baseline failures; schedule dedicated follow-up for package failures and Swift 6 cleanup
- Validation method: `swift test`, `xcodebuild`, worker tests
- Dependency notes: not blocking the current narrow fixes, but blocks a clean "production ready" claim

## Root-Cause Themes

1. The app had the right major pieces, but not a disciplined composition boundary.
2. Product surfaces were allowed to overpromise ahead of backend/runtime truth.
3. Trust-sensitive areas mixed aspirational architecture with development shortcuts.
4. Test coverage is good enough to reveal problems, but not yet enough to make every release green by default.

## Linear-to-Code Drift Analysis

### Tracked in Linear, under-realized in code

- Nearby-to-DM end-to-end reliability
- real-device BLE validation
- verified commerce/trust surfaces
- final event-mode activation behavior

### Implemented in code, underrepresented in Linear confidence

- large protocol/crypto/mesh test surface
- signing implementation and packet-level infrastructure
- meaningful architecture already present for coordinator-driven composition

## System-Wide Weaknesses

- too many features could look "done" before their runtime truth source was actually wired
- trust/security copy drifted faster than trust/security implementation
- release confidence depends on distinguishing implemented app fixes from baseline package debt
