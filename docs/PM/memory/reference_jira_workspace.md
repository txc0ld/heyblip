---
name: Jira workspace — HeyBlip (BDEV)
description: Jira Cloud at heyblip.atlassian.net is the live issue tracker as of 2026-04-25. Replaced Notion (which replaced Bugasura, which replaced Linear). Project key BDEV.
---

> **Source of truth as of 2026-04-25.** Jira BDEV is the live issue tracker. Notion HeyBlip workspace remains for narrative pages but is no longer the ticket source. Bugasura is read-only archive. See [reference_notion_workspace.md](reference_notion_workspace.md) for what stayed and what moved.

## Site

- **URL:** https://heyblip.atlassian.net
- **Project:** `BDEV` ("HeyBlip"), company-managed Scrum
- **Confluence space:** `BLIP` ("HeyBlip") — linked from BDEV → Docs tab
- **Tickets:** **BDEV-2 → BDEV-367** imported 2026-04-25 from the Notion Tasks DB. New tickets continue from BDEV-368+.

## Auth

- **Email:** `macca.mck@gmail.com`
- **API token:** in macOS Keychain, account `macca.mck@gmail.com`, service `atlassian-api-token-heyblip`. Read with:
  ```bash
  security find-generic-password -a macca.mck@gmail.com -s atlassian-api-token-heyblip -w
  ```
  Use Basic auth header `Basic base64(email:token)`.
- **Atlassian rate limits are aggressive on this token.** Sleep ≥1s between calls; ≥15s between bulk-create batches. Throttling appears as 401/404 (not 429) — confusing.

## Issue prefix

- **`BDEV-N`** — Jira's auto-numbering. Old `HEY-N` (Bugasura) IDs preserved in custom field `customfield_10039` (HEY ID); old Linear-era `BDEV-N` numbers preserved in custom field `customfield_10040` (Original BDEV ID).
- **Lookup an old HEY-N:** `JQL: "HEY ID" = "HEY-1334"` → returns the new BDEV-N.

## Default issue types (Scrum)

`Bug`, `Task`, `Story`, `Epic`, `Subtask`. (No `Improvement`, `Polish`, `Suggestion`, `Tech-Debt` — those were Notion-only types and got mapped to `Task` during import.)

## Statuses

Default Scrum workflow: `To Do`, `In Progress`, `Done`. Resolution auto-set to `Done` on transition. Other resolutions available: `Won't Do`, `Cannot Reproduce`, `Duplicate` — but the resolution field is **not on the workflow's transition screen** by default, so resolution is always set to `Done` automatically. To use other resolutions, edit the workflow's "Done" transition screen first.

## Custom fields on every imported ticket

| Field | Custom field ID | Source |
|---|---|---|
| HEY ID | `customfield_10039` | Bugasura ID (e.g. `HEY-1334`) |
| Original BDEV ID | `customfield_10040` | Old Linear-era BDEV-N |
| Notion URL | `customfield_10041` | Link back to original Notion page |
| Bugasura URL | `customfield_10042` | Link to Bugasura archive |

These are also embedded as plain text in each issue's description, so JQL `description ~ "HEY-1334"` works as a fallback.

## Common JQL

```
# Open tickets
project = BDEV AND statusCategory != Done ORDER BY priority DESC

# Find by old Bugasura ID
"HEY ID" = "HEY-1334"

# Recently shipped
project = BDEV AND statusCategory = Done ORDER BY resolutiondate DESC

# CRITICAL bugs still open
project = BDEV AND priority = Highest AND statusCategory != Done
```

## REST API quick-reference

Base: `https://heyblip.atlassian.net/rest/api/3/`

```bash
# List my open tickets
curl -u "$EMAIL:$TOKEN" "$BASE/search/jql?jql=project=BDEV+AND+statusCategory!=Done&maxResults=20" | jq

# Create a ticket
curl -X POST -u "$EMAIL:$TOKEN" -H "Content-Type: application/json" \
  "$BASE/issue" -d '{
    "fields": {
      "project": {"key":"BDEV"},
      "summary": "...",
      "issuetype": {"name":"Bug"},
      "priority": {"name":"High"},
      "labels": ["sprint-2"]
    }
  }'

# Transition to Done
curl -X POST -u "$EMAIL:$TOKEN" -H "Content-Type: application/json" \
  "$BASE/issue/BDEV-N/transitions" -d '{"transition":{"id":"31"}}'

# Bulk-create up to 50 issues
POST $BASE/issue/bulk -d '{"issueUpdates":[{"fields":{...}}, ...]}'
```

**Transition IDs (default Scrum workflow):**
- 11 = To Do
- 21 = In Progress
- 31 = Done

## What lives in Confluence vs Jira

- **Jira BDEV** — every ticket (bug, task, story, epic, sub-task) and active sprint/board work
- **Confluence BLIP** — the team home page, decisions log (`/Decisions`), components reference (`/Components` + `/BlipProtocol`, `/BlipMesh`, `/BlipCrypto`, `/blip-auth`, `/blip-relay`), narrative docs

## What got left in Notion

- The HeyBlip Notion workspace still exists with the original Tasks DB (read-only / archive). New work doesn't go there.
- Murmur (separate project) still uses Notion as control plane — not affected by this migration.

## Filing tickets — the Jira way

```bash
# Set the auth env once
export JIRA_EMAIL="macca.mck@gmail.com"
export JIRA_TOKEN=$(security find-generic-password -a macca.mck@gmail.com -s atlassian-api-token-heyblip -w)
export AUTH="-u $JIRA_EMAIL:$JIRA_TOKEN"
export BASE="https://heyblip.atlassian.net/rest/api/3"

# Create
curl -X POST $AUTH -H "Content-Type: application/json" "$BASE/issue" -d @ticket.json
```

`ticket.json`:
```json
{
  "fields": {
    "project": {"key": "BDEV"},
    "summary": "Bug: ...",
    "issuetype": {"name": "Bug"},
    "priority": {"name": "High"},
    "labels": ["audit-gaps-apr-2026"],
    "description": {
      "type": "doc",
      "version": 1,
      "content": [
        {"type": "paragraph", "content": [{"type": "text", "text": "Repro steps..."}]}
      ]
    }
  }
}
```

## Branch naming (NEW)

`type/BDEV-N-short-description` — e.g. `feat/BDEV-1192-push-smoke-test`.

Old `HEY-N` branches still exist for in-flight work; resolve them by either renaming or letting them merge under the old name (the old HEY-N is preserved in the new ticket's custom field).
