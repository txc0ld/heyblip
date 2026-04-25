---
name: Project current state and active work
description: Current repo state, open backlog, pending verifications. For pre-2026-04-22 detail see project_history_archive.md.
type: project
---

## Current state (as of 2026-04-25 EOD AWST — push-notifications session)

### Headline
**HEY-1321 production push notifications shipped end-to-end.** PR #264 (Tay) squash-merged to main as `00439c5`, plus my SOUL.md follow-up at `03de535`. TestFlight build **1.0.0 (42)** uploaded via `deploy-testflight.yml` run 24923695627. Took 11 deploy attempts to land — every failure was a real, separable issue. Trail in the merge commit body and the workflow runs.

### TestFlight
- **Build 42** (`beta-1.0.0-42` at commit `f3a9912` of the PR branch — squashed onto main as `00439c5`) on TestFlight as of 2026-04-25 ~05:38 UTC. Owed: confirm Apple finishes processing (~10 min after upload), then John installs on real device for the §5 push smoke test.
- Builds 30/31 still installable for legacy QA — they don't have NSE or new endpoints but are backwards-compat with the new auth/relay code (verified routes match).

### Workers (live)
- `blip-auth.john-mckean.workers.dev` — version `2c29ab9d` (deployed via worktree from PR branch, 2026-04-25 ~04:24 UTC). New endpoints `/v1/users/notification-prefs` and `/v1/badge/clear` live alongside the legacy routes. Two new secrets: `APNS_BUNDLE_ID_PROD`, `APNS_BUNDLE_ID_DEBUG`.
- `blip-relay.john-mckean.workers.dev` — version `ebf8bccc`. Triggers push when recipient is offline.
- `blip-cdn.john-mckean.workers.dev` — unchanged.

### Neon (live)
- Migration `002_push_notifications.sql` applied 2026-04-25 ~04:21 UTC. Additive, idempotent: `device_tokens` gained `locale`, `app_version`, `sandbox`, `last_registered_at`; new `notification_prefs` table.
- DATABASE_URL connection string is in the older `~/Documents/Vibe Coding/FezChat/FezChat/blip-memory-export/.env` (not in `~/heyblip/.claude/skills/secrets/.env`). Worth pulling into the canonical secrets file at next rotation.

### Repo
- Local `~/heyblip` clean, on `main` at `03de535`. Stash dropped.
- Two stale `.git/*.lock` files were sitting in `.git/index.lock` and `.git/objects/maintenance.lock` from 2026-04-24 — removed during this session. Same pattern `tooling_gotchas.md` documented; macOS background processes (Spotlight/`com.apple` PIDs) hold read-only FDs which look scary but don't actually conflict.
- `~/heyblip-HEY-1318` worktree still exists for John's PR #256 work (legit, leave it).
- Self-hosted runner `johns-mac` (PID 82202 on the Air, registered to `iamjohnnymac/xfit365-ios`) is running but not connected to heyblip. Future option if GitHub-hosted runners keep being unstable.

### Apple Developer Portal
- 4 App IDs: `au.heyblip.Blip`, `.debug`, `.notifications`, `.debug.notifications`. All linked to App Group `group.com.heyblip.shared`. Push enabled on the two main IDs.
- 3 fresh provisioning profiles regenerated 2026-04-25: `Blip App Store Distribution`, `Blip NSE Distribution`, `Blip Debug NSE Distribution`. All Active, expire 2027-04-12.
- APNs auth key reused: kid `97V5K3RVF3` (Team Scoped, Sandbox & Production), `.p8` at `~/Downloads/AuthKey_97V5K3RVF3.p8`.
- Two stray `.p8` files in Downloads (`AuthKey_U592D5NB99.p8`, `AuthKey_8L72H5H8CD.p8`) likely from xfit365ios — soft hygiene cleanup someday.

### CI infrastructure (the 11-attempt saga)
The `deploy-testflight.yml` workflow now handles the NSE target cleanly. Key takeaways for the next PM that has to debug it:
- **Xcode picker is hardcoded** to a preference list of GitHub-documented stable Xcode 26.x versions (26.4.1 → 26.0.1). Do NOT switch back to a discovery walk — the macos-26 image has undocumented sibling dirs (`Xcode_26.5.0.app`, `Xcode_26.5.app`, `Xcode_26.4.app`, etc.) that are partial installs whose iOS platform is missing. They fool every probe except actual archive.
- **Manual signing is pinned per-target in `project.yml`** (Release config only — Debug stays Automatic for local dev). xcodebuild's CLI doesn't expose per-target `PROVISIONING_PROFILE_SPECIFIER` overrides, and Automatic signing on CI fails ("No Accounts") because runners have no logged-in Apple ID.
- **Two profiles imported, not one** — `PROVISIONING_PROFILE` (main) + `PROVISIONING_PROFILE_NSE` (extension). Both wired via base64-decoded GitHub Actions secrets. ExportOptions.plist maps both bundle IDs.
- **App icons must be alpha-stripped** for App Store. The PR's original 3-image "single-size + appearances" set produced PNGs with alpha that the asset compiler rejected. Replaced with a full pre-rendered set (19 PNGs covering all iOS sizes + 1024×1024 marketing icon, all 8-bit RGB no alpha).

---

## Notion (post-session state)

### Closed today (2026-04-25)
| HEY | Status | Resolution |
|---|---|---|
| HEY-1321 | Fixed | Squash-merged as `00439c5`, TestFlight build 42 |
| HEY-1331 | Cancelled | Misdiagnosis — the "WebSocketTransportTOCTOUTests timing flake" was real iOS compile errors (NotificationEnrichmentCache duplicate types + missing await on @MainActor DebugLogger), all fixed in the same merge |

### Other 2026-04-25 closures (separate sweep earlier in session)
43 of the 44 "Fixed" Notion tickets transitioned to Closed with PR + commit hash notes appended. Only HEY-1279 left as Fixed (untitled body, can't verify against main without more context). HEY-1334 created and renumbered: see "Bugasura webhook + ID collision" below.

### Open backlog (verify before acting — Notion drift is a real thing)
**Strict open** = New + In Progress = 42 tickets at session end (38 New + 4 In Progress now that HEY-1321 is Fixed).

**High priority for next PM session:**
- **HEY-1192** (HIGH, In Progress) — PUSH-5 two-phone smoke test. Becomes runnable now that build 42 is live. John + 2 phones + ~30 min.
- **HEY-1318** (MEDIUM, In Progress) — foreground reconnect race, PR #256. iOS CI was previously red because of the same compile errors that ate builds 32-41. Re-run CI on PR #256 first thing — it might just go green now. If it goes red again, the new error is a real ticket worth filing.
- **HEY-1334** (HIGH, In Progress) — chat UX bugs Tay shipped as PR #265. CI green, awaiting review/merge.

**Launch-prep stack** (HEY-1322 → HEY-1328 + 1330) — 8 tickets, mostly App Store Connect manual work (privacy nutrition label, screenshots, support page on heyblip.au, debug overlay gating, moderation policy, anonymous-chat defence write-up, Info.plist purpose strings audit, channelUpdate receive-side handler).

### Bugasura webhook + ID collision
John was still creating tickets in Bugasura (HEY1322 / HEY1323 / HEY1321) on 2026-04-25 morning, even though Notion is the SOT post-2026-04-24. The webhook fires into #blip-dev. Two pollutants:
1. **HEY-1321 collision** — Bugasura HEY1321 (push notif, John's filing) ≠ Notion HEY-1321 (originally launch demo prep). Resolved by swapping IDs: Notion HEY-1321 now = push notif, launch demo moved to HEY-1333. Tay's PR #264 title `(HEY-1321)` correctly references the canonical Notion ID.
2. **HEY1322 / HEY1323** — Bugasura UX bugs, migrated into Notion as HEY-1334 with a body note linking both Bugasura tickets.

Resolution still pending: **disable the Bugasura → Slack webhook** in Bugasura notification settings to stop the noise. John knows.

---

## Open PRs (2)
- **PR #265** — `fix(chat): chat UX bugfixes (HEY-1323)` — Tay, opened 2026-04-25 morning. CI green per Tay's #blip-dev confirmation. Maps to Notion HEY-1334. Awaiting review/merge.
- **PR #256** — `fix(relay): coalesce concurrent reconnect triggers (HEY-1318)` — John, opened 2026-04-24. iOS CI was red due to PR #264's compile errors leaking into the wider workspace; now those errors are off main, re-run CI to see real status.

---

## Owed to John (manual, non-dispatchable)

1. **§5 push smoke test** on real device — install build 42 from TestFlight, ping me (next PM), I tail `wrangler tail blip-auth` and we fire the curl from `docs/OPS_APNS.md` §5. Want `push.attempted` then `push.success` with `apnsStatus=200` in the structured logs.
2. **HEY-1192 PUSH-5 two-phone test** — same as above but with two devices, verify cross-device convergence.
3. **TestFlight processing confirmation** — refresh App Store Connect → HeyBlip → TestFlight and verify build 42 is past Processing.
4. **Sentry housekeeping** — APPLE-IOS-1, -1T, -1V, -1W, -1X, -6 still need "Resolved in next release" clicks. Same items from prior sessions.
5. **Bugasura webhook off** — stop the cross-tracker noise.

---

## What the next PM should know on day-one

1. **Read SOUL.md first.** It's now wired into HANDOVER.md and PM-ORIENTATION-PROMPT.md as step 3 / first item. Don't skip it.
2. **The CI pipeline is fragile but documented.** If `deploy-testflight.yml` starts failing, read this file's "CI infrastructure" section before debugging — every trap we hit today is documented with the fix.
3. **HEY-1321 is FIXED.** Don't try to dispatch it. The Notion state is correct.
4. **PR #256 might just go green** — re-run CI before assuming HEY-1318 still needs work.
5. **Notion is SOT, but John still occasionally files in Bugasura.** Watch for ID collisions; you can swap HEY IDs cleanly via PATCH to the rich_text field if needed (see HEY-1321 ↔ HEY-1333 swap precedent in this session for the recipe).
6. **Self-hosted runner option exists** if GitHub-hosted runners go bad again. The `johns-mac` listener on the Air is registered to xfit365ios but a second instance pointed at heyblip would take ~10 min to set up and would dodge image-rotation surprises.

---

See `operating_model.md` for dispatch/merge/reviewer rules, `tooling_gotchas.md` for lessons learned, and `SOUL.md` for the voice.
