---
name: Infrastructure — Workers, Sentry, Atlassian (Jira+Confluence), DB, GitHub
description: Deployed surfaces, secrets, versions, URLs, ownership split. Updated 2026-04-25 (Bugasura→Notion→Jira migration complete).
type: reference
originSessionId: 6e15e31b-7115-4971-bf13-07d171f32b25
---
## GitHub

- **Repo:** `txc0ld/heyblip` (renamed from `FezChat` on 2026-04-14; GitHub redirects old URL). NOT `iamjohnnymac/*`.
- **Local checkout:** `~/heyblip/`. John's Finder-facing `~/FezChat/` is a separate folder for handoff notes and the plugin bundle.
- **Scheme:** Blip. **Bundle ID:** au.heyblip.Blip.
- **Build:** XcodeGen (project.yml → .xcodeproj), 3 SPM packages (BlipProtocol, BlipMesh, BlipCrypto).
- **GitHub PAT (fine-grained):** stored in `~/heyblip/.claude/skills/slack-bot/.env` as `GITHUB_PAT`. Scoped to `txc0ld/heyblip`, Contents + Pull requests read/write. Used for PR reviews, approvals, merges, marking drafts ready.
  - **Self-approval limitation:** cannot approve PRs where PAT owner (iamjohnnymac) pushed the latest commit. Workaround: merge directly without formal approval.

## TestFlight

- **Build 43** (`beta-1.0.0-43` at commit `6614568`) uploaded 2026-04-25 ~08:11 UTC via GitHub Actions workflow `24926469648` (status `success`). App Store Connect processing not yet confirmed by John as of 2026-04-25 19:30 AWST. Deployment pipeline: `.github/workflows/deploy-testflight.yml`.
- **Build 42** (`beta-1.0.0-42` at `f3a9912` of PR #264 branch, squashed onto main as `00439c5`) uploaded 2026-04-25 ~05:33 UTC via workflow `24923695627`. First successful build with NSE, push notifications + new endpoints. Took 11 deploy attempts to land — see project_history.md "CI infrastructure" section for traps.
- Build-number convention swapped from `alpha-<version>-<build>` to `beta-<version>-<build>` at build 42 with the push-notifications launch.
- Builds 29-31 still installable for legacy QA (no NSE / no new endpoints, but backwards-compat with new auth/relay code).

## Cloudflare Workers (John's account)

### blip-auth — `blip-auth.john-mckean.workers.dev`
- Registration, login, key upload, user lookup. Ed25519 challenge-response on `/v1/register`. JWT session tokens via `POST /v1/auth/token` and `POST /v1/auth/refresh` (HS256 via Web Crypto, `JWT_SECRET` as Workers secret).
- **Current deployed version: `61a29aff`** (2026-04-25 ~07:33 UTC, BDEV-368 Service Bindings rewire).
- **Service Binding:** `[[services]] RELAY = blip-relay` — auth → relay calls now go via Service Binding (was failing with CF error 1042 on workers.dev → workers.dev). Pattern must repeat for any new cross-Worker calls.
- **Push endpoints (build 42+):** `/v1/users/notification-prefs`, `/v1/badge/clear`. Push secrets: `APNS_BUNDLE_ID_PROD`, `APNS_BUNDLE_ID_DEBUG`, `APNS_ENVIRONMENT`. See `project_push_notification_secrets.md` for the silent-failure postmortem.
- **`INTERNAL_API_KEY`** rotated 2026-04-25 — shared secret with blip-relay, must match. If badge clear or push internally returns 401, that's the first thing to check.
- **Sentry:** `SENTRY_DSN` set 2026-04-21 (PR #249). `@sentry/cloudflare` instrumented. Smoke events confirmed landing.
- **DEV_BYPASS** removed entirely 2026-04-20 (PR #242 / HEY-1281).
- **Deploy:** `cd ~/heyblip/server/auth && wrangler deploy`.
- Wrangler has `compatibility_flags = ["nodejs_compat"]` from PR #249.

### blip-relay — `blip-relay.john-mckean.workers.dev`
- WebSocket relay with store-and-forward. Durable Object storage, 1hr TTL. Per-peer drain serialization (BDEV-205 / PR #149). Sender PeerID verification from packet header bytes 16-23.
- **Current deployed version: `4c6e3ae3`** (2026-04-25 ~07:32 UTC, BDEV-368 Service Bindings rewire).
- **Service Binding:** `[[services]] AUTH = blip-auth` — counterpart to auth's RELAY binding. Triggers push when recipient is offline via auth's APNs path.
- **`MAX_QUEUED_PER_PEER`** bumped 50 → 1000 on 2026-04-25 to handle fragmented-image bursts (BDEV-370).
- **`INTERNAL_API_KEY`** matches blip-auth's value.
- **JWT validation:** accepts JWT or legacy base64(noisePublicKey). Expired JWT → WebSocket close 4001. `JWT_SECRET` as Workers secret.
- **Sentry:** `SENTRY_DSN` set 2026-04-21 (PR #249). `@sentry/cloudflare` instrumented. Smoke events confirmed.
- **Foreground reconnect:** PR #253 (2026-04-21) reads live transport state on foreground. PR #256 (HEY-1318, merged 2026-04-25) coalesces concurrent reconnect triggers. Residual: BDEV-352 (3+ reconnect cycles in 1.5s, In Progress).
- **Deploy:** `cd ~/heyblip/server/relay && wrangler deploy`.
- Wrangler has `compatibility_flags = ["nodejs_compat"]`.

### blip-cdn — `blip-cdn.john-mckean.workers.dev`
- Static event manifests, public assets, avatar R2 storage. `/manifests/events.json` serves seed events. `POST /avatars/upload` (JWT-authed) stores JPEG to R2 bucket `blip-avatars`.
- **Current deployed version: `dfe703bd-b8a9-49f5-b2e3-c74c1dc9a6d2`** (2026-04-21).
- **`MANIFEST_SIGNING_KEY`** secret set 2026-04-21 with the correct Ed25519 signing key. Signed-manifest path now live. Client on build 28+ verifies `/manifests/events.json` against the matching pubkey. (See `tooling_gotchas.md` — this secret got uploaded as garbage twice before John caught it.)
- **CORS:** `*`. 1hr cache on manifests.
- **Source** in `server/cdn/`. No DB. Uses R2 + `JWT_SECRET` shared with blip-auth.

### server/verify/ stub
- Exists but is a stub (only node_modules, no source). Currently unused.

## Observability — Sentry

- **Org:** `heyblip`. **Projects:** `apple-ios` (client), `blip-auth` (worker), `blip-relay` (worker).
- PR #249 (2026-04-21): `@sentry/cloudflare` on both Workers. `DebugLogger → CrashReportingService.captureMessage` bridge. `clearUser()` on sign-out (previously zero call sites — PII leak risk closed). Scope-tag releases. Authorization header scrubbing.
- **Pending dashboard cleanup** (manual, no API): John to resolve `APPLE-IOS-1`, `-1T`, `-1V`, `-1W`, `-1X`, `-6` as "Resolved in next release" once build 43 distributes. Same items rolled forward across multiple sessions — `APPLE-IOS-1` was the `/auth/refresh` 401 cascade fixed by PR #250 pre-flight grace check; the others are pre-#248 test-harness ghosts.
- **BDEV-336:** Sentry Releases native release/dist wiring. Still open (Low priority).

## Neon Postgres (Tay's account)

- Project: `flat-boat-37766212`. Connection loaded from `.env` (`DATABASE_URL` with pooled connection string).
- Used by `blip-auth` and `blip-relay` via `DATABASE_URL` in their `wrangler.toml`.
- Key table: `users` — `id`, `username`, `email`, `noise_public_key`, `signing_public_key`, `created_at`, `updated_at`, `display_name`, `avatar_url`, `provider`, `provider_id`.

## Atlassian (Jira BDEV + Confluence BLIP)

- **Site:** https://heyblip.atlassian.net (created 2026-04-25)
- **Jira project:** `BDEV` ("HeyBlip"), company-managed Scrum. 366 tickets imported from Notion 2026-04-25, range BDEV-2 → BDEV-367. New tickets continue from BDEV-368+.
- **Confluence space:** `BLIP` ("HeyBlip"). Team home at `/wiki/spaces/BLIP/overview`. Sub-pages: Decisions log, Components reference (per SPM package + worker).
- **Auth:** `ATLASSIAN_TOKEN` env var (Basic auth `email:token`). Email `macca.mck@gmail.com`. CLASSIC token (not scoped — scoped tokens default to read-only).
- **Custom fields preserved on every imported ticket:** `HEY ID` (cf 10039), `Original BDEV ID` (cf 10040), `Notion URL` (cf 10041), `Bugasura URL` (cf 10042). Same metadata also in description text for JQL fallback.
- **Find a migrated ticket by old ID:** `JQL: "HEY ID" = "HEY-1334"`.
- **Rate limits are aggressive** — 1s between calls, 15s between bulk batches. Throttling appears as 401/404 (not 429) — confusing.
- Full reference in `reference_jira_workspace.md` and `reference_confluence_workspace.md`.

## Notion (read-only archive)

- **App URL:** https://www.notion.so/HeyBlip-34c3e435f07a80acbe11e76655af9ebf
- **Status:** archive only as of 2026-04-25. Original Tasks DB preserved for historical lookup. NOT to be edited for live work.
- Token in `NOTION_TOKEN` env var; only needed if you have to read original Notion pages.

## Bugasura (deleted 2026-04-26)

The Bugasura project was deleted entirely (not just archived). The `Bugasura URL` custom field on every imported Jira ticket (`customfield_10042`) now resolves to a 404 — kept in place as historical provenance, but don't expect click-through to work. The `HEY ID` field (`customfield_10039`) is the load-bearing cross-reference; JQL `"HEY ID" = "HEY-1334"` still finds the migrated ticket. The Bugasura → Slack webhook is gone with the project.

## Ownership split (confirmed 2026-04-14)

- **Tay owns:** Neon (Postgres DB) and Resend (email API for auth verification).
- **John owns:** Cloudflare (Workers: auth/relay/cdn, R2 bucket `blip-avatars`).
- Implication: if a Resend/Neon secret is missing or needs rotation, that's Tay's action; if a Worker secret or R2 config is missing, that's John's.
