# Tay's Dispatch Prompt for Claude Cowork

Copy the prompt below into Claude Dispatch or Cowork to begin working.

---

## Dispatch Prompt

```
I am Tay, working on Blip — a BLE mesh chat app for festivals.

## Project
- Repo: https://github.com/txc0ld/FezChat
- Linear: https://linear.app/fezchat/team/FEZ/active
- My role: Frontend, UX/UI, Design + shared backend

## Setup
1. Clone https://github.com/txc0ld/FezChat if not already cloned
2. Read these files for context:
   - CLAUDE.md (auto-loaded)
   - WORKPLAN.md — my tasks are ALL entries prefixed with "T" and the "Collaborative" section
   - README.md — project overview

## Task Management Workflow

For EVERY task I work on, follow this exact flow:

### Starting a task:
1. Check Linear (FEZ team) for my current sprint tasks. If no issues exist yet, create them from WORKPLAN.md — all "T" prefixed tasks for the current sprint. Use format:
   - Title: "T{number}: {task name}" (e.g. "T1: Onboarding flow polish")
   - Description: Copy the task description from WORKPLAN.md
   - Status: "Todo"
   - Priority: Map P0=Urgent, P1=High, P2=Medium
   - Label: "frontend" for T1-T21, "backend" for T22-T28
   - Assignee: Tay
2. Move the Linear issue to "In Progress"
3. Create a git branch: tay/T{number}-{short-description}
4. Begin implementation

### Working on a task:
- Follow CLAUDE.md build rules (no force unwraps, private by default, #Preview on all views, 44pt tap targets, accessibility)
- Read the design spec section relevant to the task before coding
- Commit frequently with conventional format: type(scope): description
- Push to the branch regularly

### Completing a task:
1. Verify the work (build succeeds, tests pass if applicable)
2. Push final commits to the branch
3. Open a PR on GitHub targeting main with a clear description
4. Move the Linear issue to "Done"
5. Add a comment on the Linear issue: what was done, any decisions made, any blockers for downstream tasks
6. Pick up the next task in sprint priority order

## Also create these Linear issues for John's tasks:
Create "J" prefixed issues for Sprint 1 if they don't exist, assigned to John:
- J1: BLE mesh integration testing
- J2: Gossip routing real-world test
- J3: Phone verification backend
- J4: WebSocket relay server

And collaborative tasks assigned to both:
- C1: Friend finder map
- C2: Medical dashboard

## Current Sprint: Sprint 1 (my tasks)

Work on these in order:
1. T1: Onboarding flow polish
2. T2: Chat UI polish
3. T3: Tab bar + navigation
4. T4: Avatar system
5. T5: App icon + branding
6. T22: Noise XX handshake validation (backend)
7. T24: SwiftData schema validation (backend)

For each task:
- Create the Linear issue if it doesn't exist
- Move to In Progress
- Branch, implement, commit, push, PR
- Move to Done
- Next task

## Rules
- Work autonomously — don't ask questions the codebase or spec can answer
- The design spec is the source of truth: docs/superpowers/specs/2026-03-28-blip-design.md
- Build command: xcodebuild -scheme Blip -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -quiet
- Test commands: swift test --package-path Packages/BlipProtocol (and Crypto, Mesh)
- Keep Linear updated at every state change — it's how John and I track progress
- If blocked, create a Linear issue tagged "blocker" and move to the next task

Begin with Sprint 1, Task T1. Go.
```
