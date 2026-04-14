# Blip Polymath Audit Todo

- [x] Phase 1: Read Bugasura first and map product intent, delivery reality, and active risk zones.
- [x] Create a clean worktree from `origin/main` for the audit/remediation branch.
- [x] Phase 2: Inspect repo structure, architecture, core services, tabs, workers, and test surfaces.
- [x] Run baseline verification to compare claimed status against executable reality.
- [x] Phase 3: Build unified issue tracker-to-code reality model.
- [x] Phase 4: Complete polymath audit with subsystem scores and root-cause themes.
- [x] Phase 5: Run specialist-agent passes and synthesize overlaps/conflicts.
- [x] Phase 6: Lock a dependency-ordered remediation plan.
- [x] Phase 7: Implement root-cause fixes with tests and observability where justified.
- [x] Phase 8: Run adversarial verification and regression checks.
- [x] Phase 9: Write all required reports under `/reports`.
- [x] Push branch, open PR against `main`, and update Bugasura with results and remaining risks.

## UI/UX Refinement Pass

- [x] Audit remaining user-facing trust and polish gaps after the first remediation pass.
- [x] Remove misleading or dead user-facing controls in shared surfaces.
- [x] Replace simulated or fallback purchase UX with real store-backed or honest unavailable states.
- [x] Make Nearby/Friend Finder reflect real runtime availability instead of fabricated map context.
- [x] Convert non-functional medical responder UI into honest build-state messaging.
- [x] Run verification and add the second report set under `/reports`.
- [x] Push the updated branch and refresh the open PR summary.

## Environment Verification Pass

- [x] Verify git remote and recent commit history in `/Users/johnmckean/FezChat`.
- [x] Verify Bugasura connectivity and list assigned issues for project HeyBlip.
- [x] Verify Slack connectivity by locating channel `#blip-dev`.
- [x] Verify the `Blip` simulator build command succeeds.
- [x] Summarize the verified environment state with branch, latest commit, and assigned issues.

## BDEV-187 Session Tokens

- [x] Node A: Read current auth flow in auth worker, relay worker, WebSocket transport, state sync, and user sync.
- [x] Nodes B-F: Add JWT issuance, refresh, validation middleware, and protect existing auth-backed endpoints.
- [x] Node G: Extend auth worker tests for token issuance, refresh, and protected endpoint behavior.
- [x] Nodes H-I: Add `AuthTokenManager`, wire it through `AppCoordinator`, and persist tokens safely in Keychain.
- [x] Nodes J-L: Replace raw-key bearer auth in HTTP services and relay transport with a token-provider flow.
- [x] Nodes N-P: Update relay auth to accept JWTs first, preserve raw-key fallback, and signal expired tokens with close code `4001`.
- [x] Node M: Run server tests, Swift package tests, `xcodegen generate`, and the simulator build.
- [x] Node Q: Push `feat/BDEV-187-session-tokens-ORIGINAL`, open a PR linked to `BDEV-187`, and post the update in `#blip-dev`.

## BDEV-181 Opus Codec

- [x] Create the task branch and inspect the existing audio codec paths.
- [x] Add `swift-opus` to `project.yml` and regenerate the Xcode project.
- [x] Replace the PCM stub encoder/decoder with real Opus encode/decode and keep backward compatibility for stored voice notes.
- [x] Update the PTT chunk path to emit real Opus frames instead of raw PCM slices.
- [x] Run package tests, regenerate the project, and run the simulator build.
- [x] Push `feat/BDEV-181-opus-codec`, open a PR linked to `BDEV-181`, and post the update in `#blip-dev`.

## BDEV-205 Drain Retry Follow-up

- [x] Inspect the current relay drain path and existing relay tests.
- [x] Replace break-on-send-error with skip-and-retry behavior in `relay-room.ts`.
- [x] Add or extend relay tests for partial drain failure, retry scheduling, and retry cleanup.
- [x] Run `cd server/relay && npm test` and `cd server/relay && npx wrangler deploy --dry-run`.
- [x] Push `fix/BDEV-205-drain-break-bug`, update PR `#148`, and post the follow-up in `#blip-dev`.

## BDEV-219 + BDEV-218 + BDEV-200 Cleanup

- [x] Create an isolated worktree, read the current Blip design spec, and inspect the rename, TLS pinning, and BLE state surfaces.
- [x] Complete BDEV-219 rename cleanup, run `xcodegen generate`, and verify the simulator build.
- [x] Complete BDEV-218 pin hash deduplication, run `swift test --package-path Packages/BlipMesh`, and verify the simulator build.
- [x] Complete BDEV-200 BLE state cleanup, run `swift test --package-path Packages/BlipMesh`, and verify the simulator build.
- [ ] Push the combined branch, open the PR linking BDEV-219/BDEV-218/BDEV-200, and post the `#blip-dev` update.

## BDEV-209 Logging Consistency

- [x] Remove consecutive duplicate or redundant `DebugLogger.emit()` lines in `MessageService.resolveRecipientPeerID`.
- [x] Switch `StateSyncService` debug logging to nonisolated `DebugLogger.emit()` while preserving redaction.
- [x] Run the package tests and simulator build, then publish the branch, PR, and Slack update.

## BDEV-210 Raw Payload Rename

- [x] Rename `Message.encryptedPayload` to `rawPayload` with the requested retry semantics comment.
- [x] Update every `encryptedPayload` read/write site in services and views, then verify there are zero remaining references.
- [x] Run package tests, generate the project if needed, run the simulator build, and publish the branch, PR, and Slack update.

## BDEV-212 Typing Indicator Context Safety

- [x] Inspect `sendTypingIndicator` and confirm it skips the fresh-context channel re-fetch used by other send paths.
- [x] Re-fetch the `Channel` in a fresh `ModelContext` after debounce and pass that local instance into `encryptAndSend`.
- [x] Run package tests, the simulator build, then push the branch, open the PR, and post the `#blip-dev` update.

## Critical Alpha Blockers

- [x] Fix BDEV-230 in `FragmentAssembler` and verify `swift test --package-path Packages/BlipProtocol`.
- [x] Fix BDEV-228 attachment action routing and verify the simulator build.
- [x] Fix BDEV-227 avatar crop image flow and verify the simulator build.
- [x] Fix BDEV-226 background message notifications and verify the simulator build.

## Auth Hardening Lane

- [x] Fix BDEV-231 500-response detail leaks and verify with `npm test` plus `grep -n '"detail"'`.
- [x] Fix the non-overlapping BDEV-233 challenge IP/rate-limit work and verify with `npm test`.

## BDEV-236 Protocol Correctness

- [x] Fix compression truncation handling in `Packages/BlipProtocol/Sources/Compression.swift`.
- [x] Fix invalid-threshold fragment splitting behavior in `Packages/BlipProtocol/Sources/FragmentSplitter.swift`.
- [x] Tighten `PacketPadding` visibility/docs and add regression coverage for documented boundary behavior.
- [x] Run `swift test --package-path Packages/BlipProtocol`.

## BDEV-237 Transport Delivery Failure

- [x] Add `didFailDelivery` to the transport delegate contract and trigger it from `TransportCoordinator` after retry exhaustion.
- [x] Bridge transport failures through `AppCoordinator` and post `.didFailMessageDelivery`.
- [x] Mark matching `Message` records as `.failed` in `MessageService` and surface the status in chat UI.
- [x] Add a BlipMesh regression test for retry exhaustion and run `swift test --package-path Packages/BlipMesh`.
- [x] Run the simulator build.

## BDEV-239 TestFlight Deploy Pipeline

- [x] Add `.github/workflows/deploy-testflight.yml` with manual dispatch + `main` push triggers.
- [x] Add `ExportOptions.plist` for App Store Connect export.
- [x] Validate required signing / App Store Connect secrets up front and clean up temp credentials on failure.
- [x] Verify the workflow YAML parses locally.

## BDEV-221 RSSI Friend Finder Bridge

- [x] Add shared `RSSIDistance` utility and regenerate the Xcode project.
- [x] Replace Nearby peer-card RSSI formatting with the shared helper.
- [x] Bridge `PeerStore` RSSI into `FriendFinderViewModel` and add `rssiMeters` to `FriendMapPin`.
- [x] Make Friend Finder pin sizing RSSI-aware.
- [x] Run `xcodegen generate`, the simulator build, and `swift test --package-path Packages/BlipProtocol`.

## BDEV-222 Proximity Ping

- [x] Add `ProximityPingPayload` to `BlipProtocol` and extend protocol tests.
- [x] Branch Friend Finder packet handling for `.proximityPing`.
- [x] Send a proximity ping when the Friend Finder map initializes.
- [x] Run the simulator build and `swift test --package-path Packages/BlipProtocol`.

## BDEV-220 Friend Finder Map Polish

- [x] Replace Friend Finder hex display names with usernames where available and assign stable friend colors.
- [x] Add a friend detail GlassCard with navigate and dismiss actions.
- [x] Add beacon-drop confirmation and guard location sharing when GPS is unavailable.
- [x] Run the simulator build.
