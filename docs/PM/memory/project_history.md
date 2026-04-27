---
name: Project current state and active work
description: Current repo state, open backlog, pending verifications. For pre-2026-04-22 detail see project_history_archive.md.
type: project
---

> **Issue tracker note:** All HEY-N references below are pre-migration Bugasura/Notion IDs. They were imported into Jira BDEV with new BDEV-N numbers but their original HEY-N is preserved on each ticket as the `HEY ID` custom field. To find the new BDEV equivalent: `JQL: "HEY ID" = "HEY-1334"`. New tickets file directly in Jira BDEV (no HEY prefix — just BDEV-N). Bugasura was deleted entirely on 2026-04-26 — `Bugasura URL` custom fields on imported tickets now 404; cross-reference via `HEY ID` instead.

## Current state (as of 2026-04-27 ~21:00 AWST — claude-pm-1 EOD handover)

### Headline
**Build 45 is uploaded to App Store Connect.** Cut from main HEAD `6cb37fb` after a 9-PR shipping spree on 2026-04-27 — all merged in one session under John's explicit per-instance authorisation. Workflow `24996458434` ran in ~5m22s, success. Apple processing in flight.

**The 9 PRs that landed today** (squashed onto main, ordered by merge time):

| PR | BDEV | Subject |
|---|---|---|
| #296 | (process) | docs(launch): consolidated manual-steps checklist for John |
| #295 | 365 + 364 + 378-followup | docs(launch): App Privacy + screenshot spec + Verifying-gate setup guide |
| #293 | 378 + 353 | chore(launch): Verifying gate process doc + relay log message clarity |
| #290 | 359 + 362 + 360 + 361 | feat(launch): Info.plist + debug overlay + reviewer notes (anonymous-chat defence + moderation process) |
| #291 | 417 | feat(observability): split mixed-fingerprint Sentry issues by [TAG] prefix |
| #294 | 366 | feat(auth): App Store reviewer OTP-bypass via env-gated branch |
| #292 | 419 | feat(auth): branded HTML verification email + plain-text fallback |
| #288 | 412 | fix(mesh): drop misleading "Less than 50m away" — RSSI is not metres |
| #289 | 410 | feat(push): explicit notification authorization at onboarding |

**Tay's frontend polish sprint dispatched.** 6 tickets (BDEV-422-427) sent via #tay-tasks parent message + 6 thread replies, each with a copy-paste-ready agent prompt. None overlap backend hot files. Recommended attack order in the parent message: 1 → 6 (skeleton loaders → empty states → animation polish → dynamic type → light mode → map UI).

**John has 4 active manual launch-prep tasks queued** (~55 min total) + 1 paused (App Store screenshots, on hold until UI is at final-candidate build). Full recipe at `docs/JOHN-MANUAL-STEPS-LAUNCH-PREP.md`.

**BDEV-413 is still the headline question.** Tay/Fabs never definitively tested Build 44 (the day moved fast onto John's launch-prep stack). Build 45 is the canonical test target. The BDEV-417 fingerprint hygiene fix means diagnostic events should now bucket under their own Sentry issue.

### TestFlight
- **Build 45** (`beta-1.0.0-45` at commit `6cb37fb`) — workflow `24996458434` completed `success` at 2026-04-27 ~13:05 UTC. Apple processing in flight at EOD.
- **Build 44** (`beta-1.0.0-44` at commit `7d169e2`) on TestFlight from 2026-04-26 EOD. Carries BDEV-413 diagnostic + BDEV-411 silent_badge_sync + BDEV-409 senderUsername. Tay/Fabs were asked to test but session moved to launch-prep before they responded.
- **Build 43** (`beta-1.0.0-43` at `6614568`) — superseded.
- Builds 30/31 still installable for legacy QA.

### Workers (live)
- `blip-auth.john-mckean.workers.dev` — **needs redeploy** to pick up #292 (BDEV-419 branded email) + #294 (BDEV-366 reviewer bypass). Both are in main but not yet in the deployed worker. Run `cd ~/heyblip/server/auth && wrangler deploy`.
- `blip-relay.john-mckean.workers.dev` — version `995bebe2` (2026-04-26, BDEV-411 silent_badge_sync). No relay PRs today; no redeploy needed.
- `blip-cdn.john-mckean.workers.dev` — unchanged.

### Repo
- `origin/main` at `6cb37fb`. **0 open iOS PRs.** All today's branches deleted both locally and remotely after squash-merge.
- Local branches: just `main` + the in-flight `docs/eod-2026-04-27-handover-sweep` (this PR).
- The stale `fix/BDEV-405-bliptests-bootstrap-crash` worktree at `~/heyblip-bdev-405` was cleaned up today.

### Apple Developer Portal
- Unchanged from 2026-04-25. Push enabled on `au.heyblip.Blip` + `.debug`. Provisioning profiles + APNs key still valid (kid `97V5K3RVF3`).

### CI infrastructure
**BDEV-404 BlipMesh CI flake escalated 2026-04-27.** Today's evidence shows ~50-100% per-run failure rate vs the ticket's "10-20%". Hits `Reconnect cycle clears...` line 48 + `throwing tokenProvider + stop...` line 84 in `WebSocketTransportTOCTOUTests.swift` every red run. PR #291 needed 3 reruns to push through. PM should bump priority + assign for investigation.

The 11-attempt deploy saga from 2026-04-25 stays solved — `deploy-testflight.yml` has handled 4 successful builds in a row (42, 43, 44, 45) without that class of failure.

---

## Jira BDEV state (post-session, 2026-04-27 ~21:00 AWST)

### Tickets shipped today (PRs merged, awaiting PM transition to Verifying/Done)
13 tickets moved To Do → In Progress today; PM should walk these through the verification gate post-merge:

- **BDEV-353** — log clarity (#293)
- **BDEV-359** — Info.plist mic string (#290)
- **BDEV-360** — anonymous-chat defence doc (#290)
- **BDEV-361** — moderation process doc (#290)
- **BDEV-362** — debug overlay gating verified (#290)
- **BDEV-363** — /support page (website PR #11, awaiting John's manual merge — bot can't push to upstream `txc0ld/heyblip.au`)
- **BDEV-365** — App Privacy declaration doc (#295) — paste step is John's
- **BDEV-366** — reviewer OTP-bypass (#294) — `wrangler secret put` step is John's
- **BDEV-378** — Verifying gate process doc + Jira setup guide (#293 + #295) — Jira admin step is John's
- **BDEV-410** — explicit notification authorization (#289)
- **BDEV-412** — RSSI-as-meters fix (#288)
- **BDEV-417** — Sentry fingerprint hygiene (#291)
- **BDEV-419** — branded HTML email (#292) — worker redeploy step is John's

### Tickets carried over from 2026-04-26 awaiting Build 45 verification
- **BDEV-413** — Noise msg2 stall — diagnostic shipped Build 44, fingerprint grouping fixed Build 45, awaits Tay/Fabs repro on 45.
- **BDEV-411, BDEV-407, BDEV-409, BDEV-405** — chain that resolves alongside BDEV-413.

### Resolved by side-effect today
- **BDEV-415** — `handleCodexPushDiag` NeonDbError. Investigation found the handler is gone in deployed `blip-auth` (zero matches in deployed code, main, or git history). Sentry issue **BLIP-AUTH-2 marked resolved** today. Jira ticket commented; PM can close with no merge.

### Tickets filed today (12 new)

| Ticket | Status | Why |
|---|---|---|
| BDEV-419 | In Progress (shipped) | Branded HTML verification email |
| BDEV-420 | To Do | (v2) Nearby Interaction UWB ranging — post-launch v2 enhancement to BDEV-412 |
| BDEV-421 | To Do | Apply to Apple for Critical Alert entitlement (SOS DnD bypass) — deferred from BDEV-410 |
| BDEV-422 | To Do | [POLISH] Skeleton loaders (Tay sprint #1) |
| BDEV-423 | To Do | [POLISH] Animation polish (Tay sprint #3) |
| BDEV-424 | To Do | [POLISH] Empty-states pass (Tay sprint #2) |
| BDEV-425 | To Do (High) | [A11Y] Dynamic Type sweep (Tay sprint #4, launch-blocker) |
| BDEV-426 | To Do | [POLISH] Light mode parity audit (Tay sprint #5) |
| BDEV-427 | To Do | [POLISH] Friend Finder map UI (Tay sprint #6) |
| BDEV-428 | To Do | [LEGAL] Register HeyBlip word mark in Australia, Class 9 |
| BDEV-429 | To Do (High) | [CHAT] Wire in-app Report flow to abuse inbox — launch-blocker |
| BDEV-430 | To Do (High, Tay) | [OPS] Email aliases on Porkbun — launch-blocker |

### Still open + still painful
- **BDEV-394** main-thread crash (To Do, High, unassigned) — recurred on Build 43; will recur on 44 + 45. 2026-04-26 investigation ruled out the original 6 candidates and surfaced 3 new suspects (`ChatListView.swift:136`, `FriendsListView.swift:145`, `StateSyncService.swift:197`). Next pass needs an authenticated simulator state.
- **BDEV-404** CI flake — escalated 2026-04-27 with full evidence (see above).
- **BDEV-429** Report-flow wiring — High priority launch-blocker, unassigned.

---

## Open PRs

**iOS: 0.** All 9 today's PRs merged.

**Website (`txc0ld/heyblip.au`):**
- **#11** — BDEV-363 /support page. Mine, awaiting John's manual merge. The bot's GitHub identity (`iamjohnnymac`) doesn't have push access on the upstream repo, so PRs land via fork → upstream and only John can click merge.
- #6, #5, #4, #3, #1 — pre-existing copy/SEO/Three.js polish PRs, mostly Tay's older work.

---

## Atlassian MCP

Added at user scope. `mcp__atlassian__*` tools resolve when OAuth is connected via Claude Code Apps panel. Until then, Jira/Confluence access is via REST + the API token in `~/heyblip/.claude/skills/secrets/.env`. Both work; REST is the more reliable path right now.

Bugasura MCP entry removed (Bugasura was deleted 2026-04-26).

---

## Owed to John (manual, non-dispatchable — EOD 2026-04-27)

1. **PAT rotation** — `GITHUB_PAT` leaked in 2026-04-25 transcript. **Still pending after 3 days.**
2. **Apple processing of Build 45** → triggers TestFlight availability for Tay/Fabs.
3. **Tay/Fabs Build 45 repro on BDEV-413** — coordinate the test.
4. **John's 4 active manual launch-prep tasks** (~55 min total, full recipe at `docs/JOHN-MANUAL-STEPS-LAUNCH-PREP.md`):
   - **Email aliases on Porkbun** (~5 min) — abuse@/support@/privacy@/hello@. https://porkbun.com/account/email/heyblip.au
   - **Reviewer OTP secrets** (~5 min) — `wrangler secret put REVIEWER_EMAIL` + `REVIEWER_OTP` on `blip-auth`
   - **App Privacy nutrition label** (~30 min) — paste from `docs/LAUNCH-APP-PRIVACY-DECLARATION.md` into ASC
   - **Jira Verifying gate setup** (~15 min) — admin UI, recipe in `docs/PROCESS-VERIFICATION-GATE-JIRA-SETUP.md`
5. **App Store screenshots — paused** until UI is at final-candidate build. Trigger: build going to App Review identified + Tay/Fabian have signed off on screen visuals.
6. **`wrangler deploy` on blip-auth** — to push #292 + #294 to production. Branded email won't reach users + reviewer bypass won't activate without it.
7. **Website PR #11 manual merge** — bot identity can't merge upstream.
8. **BDEV-410 / BDEV-412 product calls — DONE** (decisions made + shipped today).

---

## What the next PM should know on day-one

1. **Read SOUL.md first.** Wired into HANDOVER.md as step 3.
2. **The 9-PR merge spree on 2026-04-27 was a one-time grant.** John typed "yes, review and you are authorized to merge if you're satisfied" — that was scoped to the 9 PRs in front of him. The default rule (engineer stops at PR + Slack + Jira) is reactivated for the next session. Don't extrapolate.
3. **Email is on Porkbun, not Cloudflare.** MX → fwd1/fwd2.porkbun.com, SPF → _spf.porkbun.com. Don't repeat the 2026-04-27 mistake of assuming Cloudflare Email Routing.
4. **`blip-auth` needs redeploy** to pick up today's PR #292 + #294. Run `cd ~/heyblip/server/auth && wrangler deploy` once John gives the go.
5. **Website repo workflow** — push to `fork` remote (`iamjohnnymac/heyblip.au`), open PR from fork → upstream `txc0ld/heyblip.au`. Bot identity can't push or merge on the canonical repo. Confirmed today.
6. **TestFlight build commit ≠ what tester sees** until Apple processes. Build 45 workflow completed at 13:05 UTC; Apple processing typically 5-30 min more. Always check ASC TestFlight tab for actual availability.
7. **CI flake (BDEV-404) is much worse than the original ticket text.** ~50-100% per CI run today. PR #291 needed 3 reruns. PM should escalate to High + assign.
8. **Don't transition Jira tickets from engineer-agent role to Done.** PM/Cowork owns workflow. Engineer-agent allowed writes: `Assignee` → self when claiming, comment with PR URL, paste PR URL into description, transition `To Do → In Progress` only.
9. **Atlassian API gotchas** — rate limits look like 401/404 (not 429), pace ≥1s between calls. Use the plain "Create API token" button, NOT "Create with scopes".
10. **Workers cross-Worker calls require Service Bindings**, not public-URL fetch. CF returns `error code: 1042` for workers.dev → workers.dev. Auth↔relay is bound; if you add a new cross-Worker call, repeat the pattern.
11. **`INTERNAL_API_KEY` must match across blip-auth and blip-relay.** Shared secret. If badge clear or push internally returns 401, that's the first thing to check.
12. **Self-hosted runner option exists** (`johns-mac` on the Air, registered to `iamjohnnymac/xfit365-ios`) if GitHub-hosted runners go bad again. Not active for heyblip.

---

## Credentials

All in `~/heyblip/.claude/skills/secrets/.env`:
- `JIRA_EMAIL`, `JIRA_API_TOKEN`, `JIRA_BASE_URL` — Jira REST API
- `GITHUB_PAT` — `gh` CLI (use as `GITHUB_TOKEN=$GITHUB_PAT`). **Pending rotation since 2026-04-25 transcript leak.**
- `SLACK_BOT_TOKEN` — Blip bot (legacy duplicate `BLIP_BOT_TOKEN` in `.claude/skills/slack-bot/.env`)
- `NOTION_TOKEN`, `BUGASURA_API_KEY` — archived trackers

The `wrangler` CLI on this machine authenticates as `john_mckean@hotmail.com`, not `macca.mck@gmail.com`. If `wrangler tail` shows wrong workers, `wrangler logout && wrangler login`.

---
