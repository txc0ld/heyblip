---
name: Verification rules — pre-dispatch, post-deploy, ticket-vs-code
description: Three points in the pipeline where we must verify reality before trusting it — writing prompts, after worker deploys, and when treating ticket status as truth
type: feedback
originSessionId: 125d9861-ecc5-43e9-b8e7-3113e33599ef
---
Three separate incidents taught the same lesson: don't trust state at face value, verify it. These are the three spots where that lesson applies.

## 1. Verify repo state BEFORE writing a prompt

Before dispatching any task prompt, confirm the prompt references match reality:
- File paths exist (e.g., 2026-04-06: prompt referenced `Sources/Views/Components/` which didn't exist — actual path was `Sources/Views/Shared/`)
- Branches / PRs are in the expected state (stale? behind main? needs rebase?)
- Existing code doesn't already handle the request (e.g., `PermissionsStep.swift` already handled onboarding BT permission — needed to scope the task to post-onboarding only)
- The prompt itself doesn't violate CLAUDE.md (force unwraps, bare `try?`, etc.)

**Why:** Prompts posted with wrong paths / stale assumptions waste Tay's and John's time and force us to edit Slack messages mid-flight.

**How to apply:** Before writing a prompt, run `ls`, `grep`, `git log`, read the relevant source files. If anything is off, fix the prompt before posting — not after.

## 2. Verify worker deploys after `wrangler deploy`

After any Cloudflare Worker deploy, smoke-test the critical routes:
```bash
# blip-auth: token route should return 400 (not 404)
curl -s -X POST https://blip-auth.john-mckean.workers.dev/v1/auth/token \
  -H 'Content-Type: application/json' -d '{}' | grep -q "Missing noisePublicKey"
# blip-auth: health
curl -sf https://blip-auth.john-mckean.workers.dev/v1/auth/health
```

**Why:** BDEV-187 added the JWT token route on 2026-04-07 but the deploy either failed silently or never ran. The iOS app got 404 on every JWT attempt, killing the WebSocket relay for ~6 days with no one noticing. Friend requests, off-mesh DMs, and relay connectivity were all broken during that window.

**How to apply:** When a dispatch prompt includes server changes, the prompt must end with a deploy + verify step. Never mark a server ticket Done without confirming routes are live.

## 3. Verify ticket status against actual code on main

Never trust Jira ticket status at face value. Before presenting a ticket as "next to work on" or "still open":

1. `git log` for commits referencing the ticket ID (BDEV-N or the legacy HEY-N in the ticket's `HEY ID` custom field) or fixing the described issue
2. Grep the code on `main` to see if the fix is already there
3. Check for tickets incorrectly marked Done where the code wasn't actually changed (or vice versa — landed on main but still To Do in Jira)

**Why:** On 2026-04-14, presented HEY1194 (CRITICAL: group messages unencrypted) as the next task — but PR #178 had already fixed it. Also found PUSH-1 through PUSH-4 on main but tickets still open, and HEY1198/1199/1200 marked Closed with the code unchanged. Codex/Claude Code agents don't always update the issue tracker; humans don't always reopen bad closes. (This risk persisted through the 3 trackers — Bugasura → Notion → Jira BDEV. The verification rule fixes the underlying gap, not the tool.)

Separately from that: in April 2026, 4 of 15 UI audit tickets (BDEV-250/251/254/256 in the original Linear-era numbering — find the migrated equivalents via JQL `"Original BDEV ID" = "BDEV-250"`) were marked Done but main was unchanged — the PRs had empty diffs or were silently reverted. This is why prompts must carry a `## Verification` section with grep/ls/wc checks, and why post-merge we re-run those checks against `main` before transitioning to Done.

**How to apply:** Before any sprint planning or task dispatch, audit open tickets against `git log` + code search on `main`. Takes 5–10 minutes; saves hours of dispatching already-shipped work. Post-merge, re-run the prompt's verification greps against `main` before transitioning the ticket to Done.
