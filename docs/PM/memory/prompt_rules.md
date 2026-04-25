---
name: Claude Code prompt and workflow rules
description: How to write, dispatch, and manage Claude Code / Codex prompts — the full task pipeline from Jira ticket to merge
type: feedback
originSessionId: bbbc0954-8624-408e-9557-ba247c463544
---
## Task Dispatch Pipeline
1. Cowork creates Jira ticket (project BDEV) with full description **AND a `parent` Epic from the catalog** (see `reference_epic_catalog.md` — 9 Epics covering all current scope; no orphan tickets)
2. Cowork posts the FULL prompt directly in the person's task channel (#tay-tasks or #jmac-tasks) — NOT a link to Jira, NOT "check the description"
3. Person copies the prompt and pastes into Claude Code (Tay) or Codex (John, sometimes)
4. Claude Code / Codex does the work, pushes branch, opens PR, posts in #blip-dev
5. Cowork (or scheduled task) reviews PR via GitHub API, approves if clean
6. Cowork merges via GitHub PAT (squash merge)
7. Cowork transitions the Jira ticket to Done
8. (Future state) An auto-dispatch worker would pick up the next To Do for that person and repeat from step 2 — but that worker doesn't exist yet. For now, after a task lands, the next dispatch is manual: John names the next BDEV-N in chat and Cowork repeats step 2.

**Why:** John and Tay are non-technical. They should never have to go hunting for prompts in Jira ticket descriptions or figure out what to do. The prompt lands in their task channel, they copy-paste, done.

## Prompt Formatting Rules
- NEVER include "Working directory: ~/FezChat" — Claude Code already knows, and it confuses it
- NEVER use `cd ~/path/to/...` in prompts — Claude Code handles paths itself
- Always start with "Read CLAUDE.md first, then run:"
- Immediately after that, include: `Create a todo checklist from the steps below and update it as you go — check off each step when complete.` Agents lose track in long prompts without a running checklist; they skip verification, forget to push, or miss the Slack post.
- Include all context needed — the person pasting shouldn't need to look anything up
- Hand-hold: John and Tay are non-technical, prompts must do EVERYTHING
- End every prompt with:
  1. Push your branch and open a PR linked to this issue
  2. Post in #blip-dev that the fix is up
- One task per prompt — keep them self-contained
- Prompts work for both Claude Code AND Codex — keep them tool-agnostic (no tool-specific commands)

## Verification Steps in Prompts (MANDATORY)
Every prompt MUST include a `## Verification (REQUIRED before pushing):` section with concrete grep/ls/wc checks the bot must run before pushing. These prove the fix actually landed. Examples:
- Grep for the old broken pattern — must return ZERO matches
- Grep for the new expected pattern — must return at least N matches
- ls to confirm new files exist
- wc -l to check file length constraints

**Why:** In April 2026 we found 4 out of 15 UI audit tickets were marked Done without the code actually changing. The coding bot thought it made the fix, opened a PR, but the actual code on main was unchanged. Verification greps catch this at the source.

## PR Review & Merge (Cowork handles this)
- Review diffs via GitHub API using the PAT
- Approve clean PRs, request changes if issues found
- If draft PR: mark ready via GraphQL mutation, then merge
- Merge method: squash merge with conventional commit title
- **Post-merge verification (NEW):** After merging, before transitioning the Jira ticket to Done, Cowork runs acceptance checks against main — grep for the specific code changes the ticket required. Only transition to Done if the checks pass. If checks fail, transition back to In Progress (or comment why) immediately.
- After verified merge: transition Jira ticket to Done, post in #blip-dev
- **Self-approval limitation:** GitHub PAT (iamjohnnymac) cannot approve PRs where the PAT owner pushed the latest commit. Workaround: merge directly without formal approval.

## Worker Deploys
- After merging relay or auth changes, John must deploy from terminal: `cd ~/heyblip/server/<worker-name> && wrangler deploy`
- Cowork posts the deploy command in #jmac-tasks if needed

## Sprint Timelines
- Sprint dates are flexible — AI devs move fast, don't hold rigidly to dates
