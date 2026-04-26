# Tay's Dispatch Prompt for Claude Cowork

Copy the prompt below into Claude Dispatch or Cowork to begin working.

---

## Dispatch Prompt

```
I am Tay, working on HeyBlip — a BLE mesh chat app for events.

## Project
- Repo: https://github.com/txc0ld/heyblip
- Atlassian site: https://heyblip.atlassian.net
- Issue tracker: **Jira BDEV** project. Issue key prefix: BDEV-N.
- Docs: **Confluence BLIP** space — https://heyblip.atlassian.net/wiki/spaces/BLIP
- Notion HeyBlip workspace is a read-only archive — no new edits land there. Bugasura was deleted entirely on 2026-04-26.
- My role: Frontend, UX/UI, Design + shared backend.

## Setup
1. Clone https://github.com/txc0ld/heyblip if not already cloned.
2. Read these files for context:
   - CLAUDE.md (auto-loaded)
   - README.md — project overview
   - docs/superpowers/specs/blip-design.md — design source of truth
3. Read the Confluence HeyBlip Home page at https://heyblip.atlassian.net/wiki/spaces/BLIP/overview before doing anything.

## Task Management Workflow

For every task I work on, follow this exact flow:

### Starting a task
1. A Jira ticket is dispatched to me when John names a specific BDEV-N in chat. (No auto-dispatch worker — the Assignee column is informational; the chat name is what counts.)
2. Set Assignee → me on the Jira ticket. Do NOT transition status — Cowork manages transitions (To Do → In Progress → Done).
3. Create a git branch named `type/BDEV-N-short-description` (e.g. `feat/BDEV-242-adhoc-event-channels`).
4. Begin implementation per the prompt in the ticket description (or the linked Notion URL custom field for historical-context tickets).

### Working on a task
- Follow CLAUDE.md build and coding rules.
- Read the design spec section relevant to the task before coding.
- Commit with conventional commit messages (`type(scope): description`).
- Push the branch regularly.
- Stay inside the task's scope. If real work needs a path outside, stop and ask — never silently widen.

### Completing a task
1. Verify the work with the required build + all three Swift package test suites.
2. Run the verification greps from the dispatch prompt — paste output into the PR description.
3. Push final commits and open a PR on GitHub targeting `main`. Title format: `type(scope): description (BDEV-N)`.
4. Post in #blip-dev with the verification grep output + PR link.
5. STOP. Do NOT merge. Do NOT transition the Jira ticket. Cowork handles both.
6. Wait for the next dispatch — either a new Assignee assignment or a BDEV-N named in chat.

## Rules
- Work autonomously — do not ask questions the codebase or spec can answer.
- Default mode is WAIT between tasks. Don't browse the Backlog and self-select.
- The design spec is the source of truth: `docs/superpowers/specs/blip-design.md`.
- Build command: `xcodebuild -scheme Blip -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGN_IDENTITY="" CODE_SIGNING_ALLOWED=NO -quiet`
- Test commands:
  - `swift test --package-path Packages/BlipProtocol`
  - `swift test --package-path Packages/BlipCrypto`
  - `swift test --package-path Packages/BlipMesh`
- Hot files (coordinate before editing): `AppCoordinator.swift`, `MessageService.swift`, `BLEService.swift`, `WebSocketTransport.swift`, `NoiseSessionManager.swift`, `FragmentAssembler.swift`, any `Sources/Models/*` SwiftData models.
- 4 dependencies max — never add new ones without explicit approval.
- BLE features need real-device verification. Simulator does not support CoreBluetooth.
- Never merge own PR. Never transition Jira tickets — Cowork manages all status changes.
- If blocked, drop a comment on the Jira ticket and move to the next dispatched task.

## Looking up old IDs

If a ticket references an old Bugasura ID (`HEY-N`) or Linear-era number, find the Jira equivalent with:
```
JQL: "HEY ID" = "HEY-1334"
or
JQL: "Original BDEV ID" = "BDEV-17"
```

Begin by reading the Confluence HeyBlip Home and waiting for a BDEV-N dispatch. Do not self-select work.
```
