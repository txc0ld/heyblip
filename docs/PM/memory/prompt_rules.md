---
name: Claude Code prompt and workflow rules
description: How to write, dispatch, and manage Claude Code / Codex prompts — the full task pipeline from Jira ticket to merge
type: feedback
originSessionId: bbbc0954-8624-408e-9557-ba247c463544
---
## Task Dispatch Pipeline
1. PM/Cowork creates Jira ticket (project BDEV) with full description **AND a `parent` Epic from the catalog** (see `reference_epic_catalog.md` — 9 Epics covering all current scope; no orphan tickets).
2. PM posts the FULL prompt directly in the person's task channel (#tay-tasks or #jmac-tasks) — NOT a link to Jira, NOT "check the description".
3. Person copies the prompt and pastes into Claude Code (Tay), Codex (John), or a heyblip-N engineer-agent session.
4. Engineer-agent / dev does the work, transitions the ticket To Do → In Progress (allowed per the 2026-04-26 rule clarification — see slack_rules.md), pushes branch, opens PR, posts in #blip-dev.
5. PM reviews PR via GitHub API.
6. **John merges via GitHub PAT** (squash merge). PM merges only on John's explicit per-instance authorization.
7. **PR merge auto-fires the `PR merged → Verifying (BDEV-378)` Jira automation rule** (live as of 2026-04-28): if the PR title or branch contains `BDEV-N` and the ticket is currently In Progress, it auto-transitions to Verifying and posts a comment requiring a verification artefact (commit SHA, build SHA, smoke-trace note, or `skip: <reason>`).
8. PM transitions the Jira ticket from `Verifying → Done` after post-merge verification (verify change on `main` from the actual diff). The transition requires a comment containing one of the verification artefacts. Skip-path (`Done (no device verification)`) is for CI / docs / refactor / observability changes only — anything user-facing, transport, crypto, or push must go through Verifying. The skip path auto-tags the ticket with a `done-no-device-verification` label so abuse is auditable via JQL `labels = "done-no-device-verification"`.
9. (Future state) An auto-dispatch worker would pick up the next To Do for that person and repeat from step 2 — but that worker doesn't exist yet. For now, after a task lands, the next dispatch is manual: John names the next BDEV-N in chat and PM repeats step 2.

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

## PR Review & Merge
- PM reviews diffs via GitHub API using the PAT (`.claude/skills/secrets/.env` → `GITHUB_PAT`).
- Wait for green CI before recommending merge. Never recommend merging on red — the only exception is John's per-instance auth on a known-flake red.
- If draft PR: PM may flip ready via GraphQL once review passes, but only on explicit John auth.
- **John merges all PRs by default.** PM stops at "review complete, recommend merge order, comment PR URL on the Jira ticket". Never `gh pr merge` yourself — PM merges only on John's explicit per-instance authorization ("merge it"), and matches scope precisely.
- Merge method when delegated: squash merge with conventional commit title.
- **Post-merge verification (PM's responsibility):** After John merges, PM verifies the change actually landed on `main` — grep for the specific code change the ticket required, read the diff. Only transition to Done if the verification passes. If it doesn't, transition back to In Progress with a comment explaining what's missing.
- **Self-approval limitation:** GitHub PAT (`iamjohnnymac`) cannot approve PRs where the PAT owner pushed the latest commit. Workaround when merge auth is delegated: merge directly without a formal approval.

## Worker Deploys
- After merging relay or auth changes, John must deploy from terminal: `cd ~/heyblip/server/<worker-name> && wrangler deploy`
- Cowork posts the deploy command in #jmac-tasks if needed

## Sprint Timelines
- Sprint dates are flexible — AI devs move fast, don't hold rigidly to dates
