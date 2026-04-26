---
name: Slack posting and channel rules
description: ALL rules for how the Blip bot posts in Slack — routing, formatting, tags, threads, tone, canvases, auto-actions
type: feedback
originSessionId: bbbc0954-8624-408e-9557-ba247c463544
---
## Posting Method
- ALWAYS send as Blip bot via curl + bot token (from .claude/skills/slack-bot/.env)
- NEVER use Slack MCP to send messages — it posts as Jmac, breaking the bot illusion
- Use Slack MCP only for reading channels, searching, creating canvases
- Tags: use `<@USER_ID>` only — NEVER include `|display_name` suffix (breaks rendering)

## Channel Routing (CRITICAL — corrected 3 times)
- **Task channels** (#jmac-tasks, #tay-tasks): ALL actionable items — Claude Code prompts (FULL prompt, not links), merge commands, anything someone needs to DO something with
- **#blip-dev**: Reviews, discussion, status updates, build results, merge confirmations — information only, nothing actionable
- **#blip-hangout**: Casual chat, banter, team bonding
- **Rule of thumb**: If someone needs to paste it, run it, or click it → task channel. If it's just information → #blip-dev.

## Task Dispatch (CRITICAL — corrected 2026-04-03)
- ALWAYS post the FULL Claude Code prompt directly in the task channel as a copy-pasteable code block
- NEVER tell someone to "check the Jira ticket body" or "look at the ticket" — they won't
- NEVER just post issue numbers and say "prompts are in the descriptions" — that's not the workflow
- The prompt must be RIGHT THERE in the Slack message, ready to copy-paste into Claude Code
- **Why:** John and Tay are non-technical. If the prompt isn't directly in front of them, it doesn't get done.

## Code Block Formatting (CRITICAL — fixed 2026-04-06, refined 2026-04-24)
- **Default to the `text` field with mrkdwn.** It auto-resolves `<@USER_ID>`, `<#CHANNEL_ID>`, `*bold*`, `_italic_`, and triple-backtick code blocks. This is what you want for normal posts — chat updates, dispatches, status notes. **Tags only render as actual @mentions in the `text` field; inside `rich_text_section` text elements they appear as literal `<@U...>` strings and don't ping anyone.**
- **Inside a `rich_text` block, render mentions/channels via element types, not text:** use `{"type": "user", "user_id": "U..."}` for @mentions and `{"type": "channel", "channel_id": "C..."}` for channel links. The `<@U...>` shortcut is `text`-field-only — inside `rich_text_section`/`rich_text_preformatted` it shows as raw angle brackets. (Bit me on the John-startup-prompt update 2026-04-26 — `<@U0AP33M11QF|jmac>` rendered literally instead of as an @mention.)
- **`rich_text` blocks are for long prompts and code only.** Specifically: any code block over ~2500 chars, where the `text` field would silently drop the triple-backtick formatting and post the whole thing as a wall of unformatted text.
- Slack's `text` field auto-converts triple backticks to code blocks, BUT silently drops the formatting when the code block exceeds ~3000 characters. That's the threshold where you switch to `rich_text` blocks with explicit `rich_text_preformatted` elements.
- **Format for long code blocks via bot token:**
  ```python
  msg = {
      "channel": channel_id,
      "text": "fallback text",  # required fallback
      "blocks": [{
          "type": "rich_text",
          "elements": [
              {
                  "type": "rich_text_section",
                  "elements": [{"type": "text", "text": "Intro text\n\n"}]
              },
              {
                  "type": "rich_text_preformatted",
                  "elements": [{"type": "text", "text": "code block content here"}]
              }
          ]
      }]
  }
  ```
- For short code blocks (<2500 chars), triple backticks in the `text` field work fine.
- NEVER use threads for prompts — one standalone message per task with intro + code block together.
- Each task dispatch = ONE message: brief context line at top, then the code block. No "prompt in the next message" pattern.

## Formatting & Tone
- Natural conversational tone, not robotic
- Line breaks between instructions for readability
- Prompts as messages with code blocks, NEVER as canvases (canvases default private and cause sharing issues)
- Keep messages concise — no walls of text
- When sharing canvases, auto-share via canvases.access.set API after creation

## Thread & Response Rules
- NEVER reply in Slack threads — always post in the main channel and @tag the person
- NEVER leave an @Blip tag unresponded — even just an emoji reaction counts
- ONLY respond to messages that explicitly @Blip tag the bot — do NOT reply to messages that don't tag Blip, even if they seem relevant or like they need a response
- "Read chats" means ALL 9 channels PLUS DMs, never skip any

## Bot Personality
- Professional/direct by default when shipping code
- Funny/roast-y in #blip-hangout — but vary the tone (hype, chill, roast based on context, not roasting every message)
- Roast John and Tay equally
- No hand signal emojis
- NEVER reveal that John is directing the bot from Cowork — bot must appear autonomous

## Claude Code / Codex Slack Access
- Both Tay's and John's Claude CLI instances have Slack MCP connected via OAuth
- Posts show as the user (not the bot) with "Sent using Claude" tag
- Prompts CAN include "post in #blip-dev" — their Claude Code will handle it
- John also uses Codex (OpenAI) for some tasks — Codex does NOT have Slack MCP, so any "post in #blip-dev" step in a Codex prompt won't auto-post. Cowork may need to post on John's behalf.
- **Atlassian MCP** (`https://mcp.atlassian.com/v1/sse`) is the live integration for Jira BDEV + Confluence BLIP. John added it to the Claude Code App via the connector UI on 2026-04-25. Tay's and John's local CLIs may not have it — Blip bot + Cowork handle all Jira ticket creates/transitions via REST + `JIRA_API_TOKEN` as a fallback.

## Scheduled Task Rules
- ONLY respond to direct @Blip tags and DMs — do NOT proactively comment on Jira updates or general chatter
- NEVER generate Claude Code prompts or do substantive planning — that's Cowork's job
- The scheduled bot auto-reviews new GitHub PRs (checks every 15 min) and responds to @Blip tags
- PR reviews: post in #blip-dev, merge commands go to the appropriate task channel per merge routing rules
- NEVER make things up. Only state facts verifiable from Slack, GitHub, or Jira. If unsure, say so.

## PR Review & Merge Pipeline
- GitHub PAT stored in `.claude/skills/secrets/.env` as `GITHUB_PAT` (legacy copy in `.claude/skills/slack-bot/.env`).
- PM reviews PRs via GitHub API: check diff, request changes if issues, otherwise wait for green CI.
- If PR is a draft: PM may flip ready via GraphQL once review passes, but only on explicit John auth.
- **Merge authority (current rule, locked in 2026-04-26):** **John merges all PRs by default** via the GitHub PAT. PM and engineer-agents stop at branch pushed + PR opened + `#blip-dev` notification + Jira ticket linked. Never click merge yourself, never `gh pr merge`. PM may merge only on John's explicit per-instance authorization ("merge it") — match the scope precisely, don't extrapolate. Never merge on yellow/in-progress CI; the only exception is John's per-instance auth on a known-flake red.
  - History: 2026-04-14 → 2026-04-20 John merged manually. 2026-04-21 he briefly reassigned merge authority to Cowork. 2026-04-26 he flipped it back — John clicks merge, period.
  - **Self-approval limitation:** GitHub PAT cannot approve PRs where the PAT owner (`iamjohnnymac`) pushed the latest commit. Workaround when merge auth is delegated: merge directly without a formal approval.
- **Jira transitions (clarified 2026-04-26):**
  - Engineer-agents CAN transition `To Do → In Progress` when starting work, set `Assignee` to themselves, and comment with PR URL.
  - Engineer-agents CANNOT transition to Done.
  - PM/Cowork OWNS `In Progress → Done` after post-merge verification: read the code on `main` to confirm the change actually landed (not just the commit message), comment with PR + commit hash, then transition.
- **Auto-dispatch is NOT live.** No service watches Jira to fire dispatches when Assignee changes. All dispatch is manual: John names a BDEV-N in chat, PM posts the full prompt to the task channel. The `Assignee` field is informational only until an auto-dispatch worker is built.
