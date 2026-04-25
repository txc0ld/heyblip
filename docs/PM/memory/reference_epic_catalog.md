---
name: BDEV Epic catalog — 9 Epics, tag-pattern routing
description: The Epic hierarchy set up 2026-04-26 for the BDEV project. Every new ticket MUST have a `parent` Epic from this list. Adding new Epics requires explicit John approval.
type: reference
---

> **Hard rule (2026-04-26):** every new BDEV ticket created via PM/Cowork or by any engineer-agent **must** be filed with a `parent` Epic from the catalog below. No new orphan tickets. If a ticket genuinely doesn't fit any of the 9, propose a 10th Epic to John before filing — don't paper over with `Engineering Hygiene` as a default.

## The 9 Epics

| Epic | Key | Tag pattern (leading `[TAG]` in summary) |
|---|---|---|
| **Push Notifications** | [BDEV-380](https://heyblip.atlassian.net/browse/BDEV-380) | `[PUSH]`, `[APNS]`, `[NSE]` — plus `[APP]` tickets where the scope is push-specific (silent badge sync, NSE actions, push-token registration) |
| **App Store Launch** | [BDEV-381](https://heyblip.atlassian.net/browse/BDEV-381) | `[LAUNCH]` — App Store Connect manual work, privacy nutrition label, screenshots, /support page, debug-overlay gating, moderation policy, reviewer demo account |
| **Auth & Identity** | [BDEV-382](https://heyblip.atlassian.net/browse/BDEV-382) | `[AUTH]` — JWT lifecycle, refresh hardening, single-flight, Ed25519 challenge-response, AuthTokenManager correctness |
| **Chat Experience** | [BDEV-383](https://heyblip.atlassian.net/browse/BDEV-383) | `[CHAT]`, `[DM]`, `[ATTACHMENT]`, `[REACTION]` — plus `[APP]` tickets where the scope is chat-feature-specific (PTT, voice notes, saved-items interaction, group chat) |
| **Engineering Hygiene** | [BDEV-384](https://heyblip.atlassian.net/browse/BDEV-384) | `[REFACTOR]`, `[BUILD]`, `[OPS]`, `[POLISH]`, `[DOCS]`, `[PROCESS]` — refactors, build hygiene, ops tooling, design-system migrations, meta-process |
| **Handshake & Transport** | [BDEV-385](https://heyblip.atlassian.net/browse/BDEV-385) | `[NOISE]`, `[BLE]`, `[CRYPTO]`, `[RELAY]` — Noise XX correctness, BLE transport, WS relay client, peer-key rotation, reconnect coalescing, fragmentation |
| **Observability** | [BDEV-386](https://heyblip.atlassian.net/browse/BDEV-386) | `[OBS]`, `[OBSERVABILITY]`, `[SENTRY]`, `[LOG]` — Sentry instrumentation, structured-counter telemetry, log hygiene, release/dist tagging |
| **Test Infrastructure** | [BDEV-387](https://heyblip.atlassian.net/browse/BDEV-387) | `[TEST]`, `[CI]` — two-phone harness, handshake chaos, soak, App-layer test runner in CI, flaky-test fixes |
| **Web Site** | [BDEV-388](https://heyblip.atlassian.net/browse/BDEV-388) | `[WEB]` — heyblip.au content, SEO, security/pricing copy, Three.js bundle, email verification |

## How to file a new ticket with the right Epic

### Via MCP (Cowork / PM)

```
mcp__atlassian__createJiraIssue(
  cloudId = "heyblip.atlassian.net",
  projectKey = "BDEV",
  issueTypeName = "Bug" | "Task" | "Story",
  summary = "[TAG] short description",
  description = "...",
  additional_fields = {
    "priority": {"name": "High"},
    "labels": [...],
    "parent": {"key": "BDEV-38X"}    // ← Epic from catalog above
  }
)
```

If `parent` isn't in the create call, immediately follow with `editJiraIssue` to set it. Do NOT leave a ticket parentless.

### Via REST API

```bash
curl -X POST -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  "$JIRA_BASE_URL/rest/api/3/issue" -d '{
    "fields": {
      "project": {"key":"BDEV"},
      "summary": "[TAG] ...",
      "issuetype": {"name":"Bug"},
      "priority": {"name":"High"},
      "parent": {"key":"BDEV-38X"}
    }
  }'
```

### Via Jira UI (rare — engineers shouldn't be filing here)

When using the **+ Create** button, scroll to the `Parent` field and pick the appropriate Epic before saving.

## Tag → Epic decision tree (handles edge cases)

When the leading `[TAG]` is ambiguous:

- **`[APP]`** — overloaded. Look at the actual scope:
  - DM/chat/attachment/voice/reaction → **Chat Experience**
  - Push registration / NSE / badge / APNs → **Push Notifications**
  - Auth/JWT/refresh → **Auth & Identity**
  - BLE/Noise/relay/WS → **Handshake & Transport**
  - Observability/Sentry/logs → **Observability**
- **`[FEATURE]`** — pick the Epic the feature lives in (push badge counts → Push; PTT streaming → Chat; channel-update receive → Handshake & Transport).
- **No leading tag** — write one. Don't file untagged. (BDEV-325 was closed as obsolete on 2026-04-26 because it landed in Jira with summary `(untitled)` and never got a body.)

## Don'ts

- ❌ Don't create a new Epic without John's approval. Catalog is intentionally small.
- ❌ Don't park a ticket under "Engineering Hygiene" as a default if it really belongs elsewhere — that bucket is for genuine cross-cutting refactor/process work, not "miscellaneous."
- ❌ Don't leave a new ticket without a parent. The whole point of this catalog is no orphans.

## When something doesn't fit

If you genuinely have a ticket scope that none of the 9 Epics covers, the right move is:

1. File the ticket WITHOUT a parent.
2. Immediately ping John in `#jmac-tasks` (or chat) with the ticket key + a one-sentence pitch for the new Epic.
3. Once approved, create the Epic, set `parent` on the orphan, and add the new Epic + tag pattern to this catalog.

— maintained by claude-pm-1, last updated 2026-04-26
