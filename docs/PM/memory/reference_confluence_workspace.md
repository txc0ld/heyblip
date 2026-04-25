---
name: Confluence workspace — HeyBlip (BLIP)
description: Confluence Cloud at heyblip.atlassian.net/wiki hosts the HeyBlip team docs, decisions log, and component reference. Linked to Jira project BDEV.
---

## Site

- **URL:** https://heyblip.atlassian.net/wiki/spaces/BLIP
- **Space key:** `BLIP`
- **Space ID:** `458754`
- **Home page ID:** `458861` ("HeyBlip Home")
- **Linked Jira project:** `BDEV`

## Auth

Same Atlassian API token as Jira — see [reference_jira_workspace.md](reference_jira_workspace.md).

## Page tree

```
HeyBlip Home (458861)               ← team overview, quick links, live Jira embeds
├── Decisions (131238)              ← decision log; type /decision on the page
└── Components (524291)             ← architectural component reference
    ├── BlipProtocol (491523)
    ├── BlipMesh (131258)
    ├── BlipCrypto (65760)
    ├── blip-auth (524311)
    └── blip-relay (589835)
```

## Conventions

- **Decisions** carry a stable `DEC-N` ID in the title (e.g. `DEC-14: Notion is control plane`). Use Confluence's inline `/decision` action, not free-form text.
- **Components** mirror the SPM package layout in the iOS repo. Each has owner, repo path, description, and a JQL-filtered "open tickets" view.
- **The Home page** uses live Jira macros (issues table, status pie chart, priority pie chart). Don't paste static counts.

## Macros worth knowing

| Macro | Usage |
|---|---|
| `jira` | Live ticket table from BDEV via JQL — `<ac:structured-macro ac:name="jira">` with `jqlQuery` parameter |
| `jirachart` | Pie chart of issues by status/priority/assignee/etc. |
| `decision` | Inline decision (use `/decision` in editor — not via API) |
| `expand` | Collapsible section |
| `panel` | Coloured callout |
| `children` | Auto-list child pages |
| `recently-updated` | Activity feed |

## API quick-reference

```bash
BASE="https://heyblip.atlassian.net/wiki"

# Read a page (storage format)
curl -u "$EMAIL:$TOKEN" "$BASE/api/v2/pages/458861?body-format=storage" | jq

# Update a page (must include version+1 and full body)
curl -X PUT -u "$EMAIL:$TOKEN" -H "Content-Type: application/json" \
  "$BASE/api/v2/pages/458861" -d '{
    "id": "458861",
    "status": "current",
    "title": "HeyBlip Home",
    "spaceId": "458754",
    "body": {"representation": "storage", "value": "<storage XML>"},
    "version": {"number": <current+1>, "message": "..."}
  }'

# Create a child page
curl -X POST -u "$EMAIL:$TOKEN" -H "Content-Type: application/json" \
  "$BASE/api/v2/pages" -d '{
    "spaceId": "458754",
    "parentId": "458861",
    "status": "current",
    "title": "...",
    "body": {"representation": "storage", "value": "..."}
  }'

# Rename a space (the v2 API doesn't support PUT — use v1)
curl -X PUT -u "$EMAIL:$TOKEN" -H "Content-Type: application/json" \
  "$BASE/rest/api/space/BLIP" -d '{"name":"NewName"}'
```

## Storage format gotchas

- Confluence normalises macro markup — adds `ac:schema-version` and `ac:macro-id` attributes after PUT. Don't string-match macro definitions; use regex with `[^>]*` to be tolerant of these injections.
- Custom field references in Jira macros: use the field's name in JQL (e.g. `"HEY ID"`) not the customfield_NNNNN ID.
- The `decisionlist` macro doesn't exist in Cloud — use the `/decision` inline action and a child Decisions page.
- The `children` macro that points at a specific page needs the page to actually exist when the macro renders, or it shows "Unable to render {children}".

## Permissions model

- **Team has read+write** via `ALL_LICENSED_USERS` → all 3 Confluence-licensed users (John, Tay, Fabian) can read/write everywhere in BLIP.
- **John has admin** explicitly.
- **`Microsoft Teams for Confluence Cloud`** and **`Chat Notifications`** appear as users in the permission list — these are pre-installed Atlassian app integrations, not real people. Safe to ignore.

If you ever need to scope access more strictly (e.g. a 4th Confluence user shouldn't see HeyBlip), remove `ALL_LICENSED_USERS` from the BLIP space permissions and add the 3 explicitly.
