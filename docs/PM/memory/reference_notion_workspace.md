---
name: Notion workspace — HeyBlip (SUPERSEDED — read-only archive)
description: Was the issue tracker 2026-04-24 to 2026-04-25. Now read-only archive. Use reference_jira_workspace.md for live Jira BDEV. Kept for historical lookup only.
type: reference
originSessionId: 134ab6d3-3752-4978-ae5b-a3722cdc2970
---

> **SUPERSEDED 2026-04-25.** Jira BDEV at heyblip.atlassian.net is now the live issue tracker — see [reference_jira_workspace.md](reference_jira_workspace.md). The Notion HeyBlip workspace remains as a read-only archive. Every Jira ticket has a `Notion URL` custom field linking back to its original Notion page for historical lookup. Do not file new tickets or make edits in Notion.

The schemas/IDs/patterns below remain accurate for read-only API queries against the archive but must not be used for write operations.

## Workspace overview

- **Workspace name:** `HeyBlip`
- **Hub page URL:** https://www.notion.so/HeyBlip-34c3e435f07a80acbe11e76655af9ebf
- **Hub page ID:** `34c3e435-f07a-80ac-be11-e76655af9ebf`
- **Bot identity (Cowork integration):** `Claude.ai HeyBlip`
- **Bot user ID:** `34c3e435-f07a-8197-888b-00278b5caec3`

## Auth

- **Personal integration token: see `docs/PM/SECRETS.md` (loaded from `~/heyblip/.claude/skills/secrets/.env` as `$NOTION_TOKEN`).
- **API base:** `https://api.notion.com/v1`
- **Required headers:** `Authorization: Bearer <token>` + `Notion-Version: 2022-06-28` + `Content-Type: application/json`.

The MCP integration (`mcp__7d3bd0a7-...`) is separately authenticated and currently wired to the Murmur workspace, NOT HeyBlip — so MCP fetch on HeyBlip page IDs returns 404. Use the personal token + REST API directly until the MCP integration is added to the HeyBlip workspace.

## Hub page structure

Top-to-bottom blocks on the hub:
1. 🤖 callout — "If you are an agent, read this." Contains links to the orientation page, CLAUDE.md, and the source-of-truth declaration. Block ID: `34c3e435-f07a-818f-b73f-cbb511221d14`.
2. Stats callout — task / decision / component / commit counts. Block ID: `34c3e435-f07a-81bf-87d6-e234e861c075`.
3. "What is HeyBlip" heading + elevator pitch quote.
4. Tasks heading + description callout (block ID `34c3e435-f07a-8170-8901-f9f34be23ff8`) + Tasks DB inline.
5. Decisions heading + Decisions DB inline.
6. Components heading + Components DB inline.
7. "Other pages in this hub" — links the heyblip.au sub-page.

## Tasks DB

- **Database ID:** `34c3e435-f07a-8175-bbdd-e0c455d106f7`
- **Issue prefix:** `HEY-N` (continued from the Bugasura import).
- **Next available ID:** check by querying sorted by HEY ID descending. As of 2026-04-24 EOD, max is HEY-1333.

### Schema

| Property | Type | Notes |
|---|---|---|
| `Name` | title | Free-form. Convention: `[AREA] Title` (e.g. `[RELAY]`, `[APP]`, `[LAUNCH]`, `[CHAT]`, `[OPS]`). |
| `HEY ID` | rich_text | `HEY-N` format. Required for traceability. |
| `Status` | select | `New`, `In Progress`, `Fixed`, `Not Fixed`, `Released`, `Cancelled`, `Closed` |
| `Severity` | select | `CRITICAL`, `HIGH`, `MEDIUM`, `LOW` |
| `Type` | select | `BUG`, `FEATURE`, `IMPROVEMENT`, `POLISH`, `SUGGESTION`, `TASK`, `TECH-DEBT` |
| `Sprint` | select | `Linear Import`, `Audit Gaps — Apr 2026` |
| `Assigned to` | select | Agent handles: `claude-1`, `claude-2`, `claude-3`, `claude-4`, `claude-6`, `any` |
| `Owner` | text | The agent's claim. Set by the agent when starting; Cowork doesn't touch this. |
| `Creator` | text | Free-form. |
| `PR URL` | url | Set when the PR is up. |
| `Bugasura URL` | url | Historical reference for tickets imported from Bugasura. Empty for net-new Notion tickets. |
| `Approved to merge` | checkbox | Maintainer-owned. |
| `Created` | date | Auto. |
| `Closed` | date | Set when status moves to `Fixed`/`Closed`. Maintainer-owned. |

### Canonical query — list all open tasks in the Linear Import sprint

```bash
curl -s -X POST -H "Authorization: Bearer $NOTION_TOKEN" -H "Notion-Version: 2022-06-28" -H "Content-Type: application/json" \
  "https://api.notion.com/v1/databases/34c3e435-f07a-8175-bbdd-e0c455d106f7/query" \
  -d '{
    "filter": {
      "and": [
        {"property": "Sprint", "select": {"equals": "Linear Import"}},
        {"property": "Status", "select": {"does_not_equal": "Closed"}}
      ]
    },
    "page_size": 100
  }'
```

### Canonical create — file a new ticket

```bash
curl -s -X POST -H "Authorization: Bearer $NOTION_TOKEN" -H "Notion-Version: 2022-06-28" -H "Content-Type: application/json" \
  "https://api.notion.com/v1/pages" \
  -d '{
    "parent": {"database_id": "34c3e435-f07a-8175-bbdd-e0c455d106f7"},
    "icon": {"type": "emoji", "emoji": "🎯"},
    "properties": {
      "Name":     {"title":      [{"text": {"content": "[AREA] Short title"}}]},
      "HEY ID":   {"rich_text":  [{"text": {"content": "HEY-N"}}]},
      "Status":   {"select":     {"name": "New"}},
      "Severity": {"select":     {"name": "MEDIUM"}},
      "Type":     {"select":     {"name": "BUG"}},
      "Sprint":   {"select":     {"name": "Linear Import"}}
    },
    "children": [
      {"object":"block","type":"paragraph","paragraph":{"rich_text":[{"type":"text","text":{"content":"Body text — full Claude Code prompt goes here."}}]}}
    ]
  }'
```

### Canonical status transition

```bash
curl -s -X PATCH -H "Authorization: Bearer $NOTION_TOKEN" -H "Notion-Version: 2022-06-28" -H "Content-Type: application/json" \
  "https://api.notion.com/v1/pages/<page-id>" \
  -d '{"properties": {"Status": {"select": {"name": "Fixed"}}}}'
```

### Find page ID by HEY ID

```bash
curl -s -X POST -H "Authorization: Bearer $NOTION_TOKEN" -H "Notion-Version: 2022-06-28" -H "Content-Type: application/json" \
  "https://api.notion.com/v1/databases/34c3e435-f07a-8175-bbdd-e0c455d106f7/query" \
  -d '{"filter": {"property": "HEY ID", "rich_text": {"equals": "HEY-1245"}}, "page_size": 1}'
```

## Decisions DB

- **Database ID:** `34c3e435-f07a-8178-812d-cc6e712d32e9`
- **ID prefix:** `DEC-N`
- **Purpose:** Why is it done this way? Long-form architectural decisions, browsable, citable.

## Components DB

- **Database ID:** `34c3e435-f07a-811b-902b-fd802b1518e4`
- **Purpose:** Internal structure of the HeyBlip app. Mirrors the SPM package layout (`BlipProtocol`, `BlipMesh`, `BlipCrypto` + app target).

## Sub-pages under the hub

- **Fresh agent orientation:** https://www.notion.so/Fresh-agent-orientation-34c3e435f07a81f981a6f2a8be4114eb — paste-as-prompt template for spinning up new agents in WAIT mode. Single starting point.
- **heyblip.au — Website:** sub-page tracking the marketing site work. Has its own Tasks / Decisions / Components DBs scoped to website concerns.

## Bugasura — read-only archive

- **URL:** https://my.bugasura.io/HeyBlip
- All Bugasura tickets imported into Notion preserve their HEY-N IDs and link back via the `Bugasura URL` property. No new edits should land in Bugasura.

## Gotchas

- **Notion code blocks have a 2000-char limit per `rich_text` segment.** For longer code blocks, split into multiple text segments inside the same block — they concatenate visually.
- **Notion API doesn't accept raw markdown.** Block array must be built from typed blocks (`paragraph`, `heading_2`, `code`, `bulleted_list_item`, etc.).
- **Status is a `select`, not a `status` property type.** The schema uses Notion's older `select` type — patch as `{"Status": {"select": {"name": "Fixed"}}}`, not `{"Status": {"status": ...}}`.
- **HEY ID format includes the dash.** `HEY-1308` not `HEY1308`. Filter queries fail silently if the format is wrong.
- **Sync from Bugasura is one-way + lagged ~hours.** As of 2026-04-24, Bugasura → Notion sync is still running for older tickets but Notion is the new write side. Reconcile policy TBD (HEY-1332).
