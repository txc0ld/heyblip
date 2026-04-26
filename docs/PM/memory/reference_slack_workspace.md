---
name: Slack workspace — The Mesh
description: Slack workspace details, channel IDs, bot token location, and canvas links for team coordination
type: reference
originSessionId: bbbc0954-8624-408e-9557-ba247c463544
---
Workspace: **The Mesh** (`the-mesh-group.slack.com`)
Team ID: T0APGERE0BG

Channels:
- #all-the-mesh (C0APF4L9AKX) — announcements, cross-project updates
- #blip-dev (C0AQCQZVBCG) — Blip dev: PRs, builds, deploys, testing (renamed from #fezchat-dev)
- #blip-website (C0APV45UF6G) — Blip website issues, routed from Bugasura WDEV team
- #blip-hangout (C0AQD990D3J) — casual chat for Blip team
- #blip-tech (C0AQNJK10SW) — deep technical discussions, architecture, protocol design, competitive analysis
- #tay-tasks (C0APT84EXAS) — Tay's daily dispatch prompts and task context
- #jmac-tasks (C0AQPJB908G) — John's daily dispatch prompts and task context
- #blip-marketing (C0AQUJWQS3T) — marketing strategy and campaigns
- #blip-monetisation (C0AQC9X4X8V) — monetisation strategy, IAP, pricing
- #social (C0APXDXL6V7) — non-work chat

Members:
- John (Jmac) — U0AP33M11QF (workspace owner)
- Taylor Mayor (tx --) — U0APF5888J1 (tmayorx@gmail.com)
- Fabs (fgullotti) — U0AQ0A6L4RM (Fgullotti@gmail.com) — marketing & monetisation, Perth timezone

Blip Bot:
- App ID: A0APDURFTMH
- Bot User ID: U0APGUH16SZ
- Bot token stored at: `~/heyblip/.claude/skills/secrets/.env` as `SLACK_BOT_TOKEN` (canonical), with a legacy duplicate at `~/heyblip/.claude/skills/slack-bot/.env` as `BLIP_BOT_TOKEN`. Both env names hold the same xoxb- token.
- Scopes: canvases:read, canvases:write, chat:write, chat:write.public, channels:join, channels:read, groups:read, files:read, channels:history, reactions:write, reactions:read, im:history, im:read, groups:history, files:write, users:read, pins:write, pins:read, bookmarks:read, bookmarks:write
- **Can download Slack files** via bot token: `curl -s -H "Authorization: Bearer $BLIP_BOT_TOKEN" "<url_private_download>"` — use conversations.history API to get file URLs first
- **Can read DMs** to the bot via im:history + im:read scopes
- Bot is joined to: #blip-hangout, #blip-dev, #blip-tech, #tay-tasks, #jmac-tasks, #blip-marketing, #blip-monetisation
- **ALWAYS send messages as the Blip bot** using curl + bot token, not via the Slack MCP (which sends as Jmac)
- Use Slack MCP for reading channels, searching, creating canvases, etc. — just not for sending messages

To send as bot:
```
source ~/heyblip/.claude/skills/secrets/.env
curl -s -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"channel":"CHANNEL_ID","text":"message"}'
```

Canvases:
- Blip Project Hub: https://the-mesh-group.slack.com/docs/T0APGERE0BG/F0APXS7U673
- BLE Test Checklist: F0APDQV5HGB
- Merge to Main prompt: F0APJPK6946
- FEZ-63 prompt: F0APJPS0HQW

Connected MCPs: Slack MCP is active for The Mesh workspace.
