# Blip Polymath Audit Todo

- [x] Phase 1: Read Linear first and map product intent, delivery reality, and active risk zones.
- [x] Create a clean worktree from `origin/main` for the audit/remediation branch.
- [x] Phase 2: Inspect repo structure, architecture, core services, tabs, workers, and test surfaces.
- [x] Run baseline verification to compare claimed status against executable reality.
- [x] Phase 3: Build unified Linear-to-code reality model.
- [x] Phase 4: Complete polymath audit with subsystem scores and root-cause themes.
- [x] Phase 5: Run specialist-agent passes and synthesize overlaps/conflicts.
- [x] Phase 6: Lock a dependency-ordered remediation plan.
- [x] Phase 7: Implement root-cause fixes with tests and observability where justified.
- [x] Phase 8: Run adversarial verification and regression checks.
- [x] Phase 9: Write all required reports under `/reports`.
- [x] Push branch, open PR against `main`, and update Linear with results and remaining risks.

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
- [x] Verify Linear connectivity and list assigned issues for team `Blip Dev`.
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

## BDEV-209 Logging Consistency

- [x] Remove consecutive duplicate or redundant `DebugLogger.emit()` lines in `MessageService.resolveRecipientPeerID`.
- [x] Switch `StateSyncService` debug logging to nonisolated `DebugLogger.emit()` while preserving redaction.
- [x] Run the package tests and simulator build, then publish the branch, PR, and Slack update.

## BDEV-210 Raw Payload Rename

- [x] Rename `Message.encryptedPayload` to `rawPayload` with the requested retry semantics comment.
- [x] Update every `encryptedPayload` read/write site in services and views, then verify there are zero remaining references.
- [x] Run package tests, generate the project if needed, run the simulator build, and publish the branch, PR, and Slack update.
