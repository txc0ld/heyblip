# Tay's Dispatch Prompt for Claude Cowork

Copy the prompt below into Claude Dispatch or Cowork to begin working.

---

## Dispatch Prompt

```
I am Tay, working on HeyBlip - a BLE mesh chat app for events.

## Project
- Repo: https://github.com/txc0ld/heyblip
- Issue tracker: Bugasura (HeyBlip project - https://my.bugasura.io/)
- My role: Frontend, UX/UI, Design + shared backend

## Setup
1. Clone https://github.com/txc0ld/heyblip if not already cloned
2. Read these files for context:
   - CLAUDE.md (auto-loaded)
   - README.md - project overview
   - docs/superpowers/specs/blip-design.md - design source of truth

## Task Management Workflow

For every task I work on, follow this exact flow:

### Starting a task
1. Check Bugasura for my assigned HeyBlip issues
2. Move the selected Bugasura issue to "In Progress"
3. Create a git branch named for the ticket and task
4. Begin implementation

### Working on a task
- Follow CLAUDE.md build and coding rules
- Read the design spec section relevant to the task before coding
- Commit with conventional commit messages
- Push the branch regularly

### Completing a task
1. Verify the work with the required build and any relevant tests
2. Push the final commits to the branch
3. Open a PR on GitHub targeting `main` with a clear description
4. Move the Bugasura issue to "Fixed"
5. Add a Bugasura comment summarizing what changed, any decisions made, and any downstream blockers
6. Pick up the next assigned Bugasura task

## Rules
- Work autonomously - do not ask questions the codebase or spec can answer
- The design spec is the source of truth: docs/superpowers/specs/blip-design.md
- Build command: xcodebuild -scheme Blip -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGN_IDENTITY="" CODE_SIGNING_ALLOWED=NO -quiet
- Test commands: swift test --package-path Packages/BlipProtocol, swift test --package-path Packages/BlipCrypto, swift test --package-path Packages/BlipMesh
- Keep Bugasura updated at every state change - it is the team source of truth
- If blocked, document the blocker in Bugasura and move to the next available task

Begin by checking Bugasura for the highest-priority assigned issue. Go.
```
