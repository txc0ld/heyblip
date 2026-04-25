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

- **Build 29** (`alpha-1.0.0-29` at commit `537100d`) uploaded 2026-04-21 via GitHub Actions workflow `24713328183`. Deployment pipeline: `.github/workflows/deploy-testflight.yml`.
- **Build 28** (`alpha-1.0.0-28` at `fc1ffcc`, PR #235) was the prior shipping build.
- Build-number convention: `alpha-<version>-<build>`.

## Cloudflare Workers (John's account)

### blip-auth — `blip-auth.john-mckean.workers.dev`
- Registration, login, key upload, user lookup. Ed25519 challenge-response on `/v1/register`. JWT session tokens via `POST /v1/auth/token` and `POST /v1/auth/refresh` (HS256 via Web Crypto, `JWT_SECRET` as Workers secret).
- **Sentry:** `SENTRY_DSN` set 2026-04-21 (PR #249). `@sentry/cloudflare` instrumented. Smoke events confirmed landing.
- **APNS_ENVIRONMENT** secret set 2026-04-20 — production push working. See `project_push_notification_secrets.md` for the silent-failure postmortem.
- **DEV_BYPASS** removed entirely 2026-04-20 (PR #242 / HEY-1281).
- **Deploy:** `cd ~/heyblip/server/auth && wrangler deploy`.
- Wrangler has `compatibility_flags = ["nodejs_compat"]` from PR #249.

### blip-relay — `blip-relay.john-mckean.workers.dev`
- WebSocket relay with store-and-forward. Durable Object storage, 50 packets/peer cap, 1hr TTL. Per-peer drain serialization (BDEV-205 / PR #149). Sender PeerID verification from packet header bytes 16-23.
- **JWT validation:** accepts JWT or legacy base64(noisePublicKey). Expired JWT → WebSocket close 4001. `JWT_SECRET` as Workers secret.
- **Sentry:** `SENTRY_DSN` set 2026-04-21 (PR #249). `@sentry/cloudflare` instrumented. Smoke events confirmed.
- **Foreground reconnect fix:** PR #253 (2026-04-21) — reads live transport state on foreground instead of cached. Known residual issues: HEY1310/1311 (tech debt, review follow-up), HEY1318 (foreground multi-reconnect race, MEDIUM).
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
- **Watch after build 29:** `APPLE-IOS-1` (163 events / 29 users, `/auth/refresh` 401 cascade). Fixed by PR #250 pre-flight grace check — should go dark once users pick up build 29.
- **Pending dashboard cleanup** (manual, no API): John to resolve `APPLE-IOS-6`, `-1T`, `-1V`, `-1W`, `-1X` as "Resolved in next release" once build 29 distributes. These are pre-#248 test-harness ghosts.
- **HEY1288:** Sentry Releases scope-tag → native migration. Still open.

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

## Bugasura (read-only archive)

- **App URL:** https://my.bugasura.io/
- **IDs:** project 135167 (HeyBlip), team 101842 (Mesh Works), sprint 152746 (Linear Import). Issue prefix **HEY** (preserved as Jira custom field).
- Each Jira ticket has a `Bugasura URL` custom field linking back. Click-through is the easiest path for historical lookups; the API is rarely needed now.
- Full historical API reference in `reference_bugasura_api.md`.

## Ownership split (confirmed 2026-04-14)

- **Tay owns:** Neon (Postgres DB) and Resend (email API for auth verification).
- **John owns:** Cloudflare (Workers: auth/relay/cdn, R2 bucket `blip-avatars`).
- Implication: if a Resend/Neon secret is missing or needs rotation, that's Tay's action; if a Worker secret or R2 config is missing, that's John's.
