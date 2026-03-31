# Final Verification

## Commands Run

### Native app

- `xcodegen generate`
- `xcodebuild -project Blip.xcodeproj -scheme Blip -destination 'generic/platform=iOS Simulator' -quiet build`
- `xcodebuild -project Blip.xcodeproj -scheme Blip -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:BlipTests/ChatViewModelTests test -quiet`
- `xcodebuild -project Blip.xcodeproj -scheme Blip -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:BlipTests test`

### Swift packages

- `swift test --package-path Packages/BlipProtocol`
- `swift test --package-path Packages/BlipMesh`
- baseline earlier in session: `swift test --package-path Packages/BlipCrypto`

### Workers

- `npm test` in `server/auth`
- `npm test` in `server/relay`

## Results

### Passed

- project generation succeeded
- native simulator build succeeded on final diff
- `BlipTests/ChatViewModelTests` passed
- full `BlipTests` XCTest pass was observed at `117 tests, 0 failures`
- `Packages/BlipProtocol` passed: `157 tests`
- `server/auth` passed: `21 tests`
- `server/relay` passed: `24 tests`

### Passed With Warnings

- native build still emits broad pre-existing concurrency/sendability warnings, especially around `nonisolated(unsafe)` and observer captures

### Pre-existing failures still present on main

- `Packages/BlipMesh`: `GossipMultiHopTests` still fails the TTL expectation
  - observed failure: `TTL=3 packet reaches nodes 0-2 but not nodes 3 or 4`
- earlier baseline `Packages/BlipCrypto` run failed in `Noise XX Handshake Validation - T22`

These failures were not introduced by this branch; they were visible during baseline verification before publication.

## Manual Validation Notes

- code inspection confirmed the coordinator is now the composition root for chat, festival, and profile flows
- code inspection confirmed sign-out now clears identity and local persisted state
- code inspection confirmed unsupported verification/account actions no longer pretend to complete real work
- README now reflects the actual transport-trust posture instead of overstating confidentiality

## Unresolved Risks

1. Private-message confidentiality is still incomplete because app-level Noise encryption is not fully wired.
2. Real-device BLE validation remains necessary despite simulator/unit coverage.
3. Swift concurrency warnings remain wide enough to threaten future Swift 6 adoption.
4. `BlipMesh` and `BlipCrypto` package baselines are not fully green.

## Monitoring Recommendations

1. Track real-device BLE discovery, DM creation, and delivery latency across two phones before release.
2. Monitor auth-worker requests for rejected/sanitized payload fields after deploying the hardening change.
3. Treat any user-facing encryption/compliance messaging as blocked until Noise transport is fully wired and verified end-to-end.
4. Open follow-up Linear work for package-baseline cleanup and Swift 6 warning reduction before any production-readiness claim.
