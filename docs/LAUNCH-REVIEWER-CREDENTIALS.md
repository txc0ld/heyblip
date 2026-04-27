# App Store Reviewer Credentials & Test Plan

**Audience:** Internal — John (App Store Connect submission)
**Ticket:** [BDEV-366](https://heyblip.atlassian.net/browse/BDEV-366)
**Last reviewed:** 2026-04-27
**Sensitivity:** Reviewer credentials (`REVIEWER_EMAIL` + `REVIEWER_OTP`) are NOT committed to the repo. They live in Cloudflare Worker secrets + App Store Connect submission notes.

## What this is

A documented OTP-bypass path for App Store reviewers, plus the test-plan template that goes into the App Store Connect submission notes.

Apple's reviewer fleet sits behind shared infrastructure; phone-OTP and email-OTP gates routinely fail for them (different countries, automated test rigs, blocked SMS/email pipelines). HeyBlip's `/v1/auth/send-code` → `/v1/auth/verify-code` flow has a documented bypass for one specific reviewer email so review can complete.

## How the bypass works

When BOTH of these are set in the `blip-auth` Worker secrets, the bypass is active:

- `REVIEWER_EMAIL` — the email Apple's reviewer will enter at sign-up (e.g. `apple-reviewer@heyblip.au`)
- `REVIEWER_OTP` — the static OTP they enter on the next screen (e.g. `123456`)

Flow:

1. Reviewer enters `REVIEWER_EMAIL` in the OTP-prompt screen.
2. App calls `/v1/auth/send-code`.
3. Server detects the reviewer email match (case-insensitive). **No email is dispatched.** The static `REVIEWER_OTP` is seeded directly into the auth Worker's KV with the normal TTL (10 min). Server returns `sent: true` so the app advances to the verify screen.
4. Reviewer enters `REVIEWER_OTP` in the verify screen.
5. App calls `/v1/auth/verify-code`. Standard verify path runs — code matches, KV entry deleted, returns `verified: true`.
6. Onboarding continues through `Create profile → Permissions → Done` exactly as a real user.

If either env var is unset, the bypass is **OFF** (fail-safe). Both must be present for the branch to fire. See `server/auth/test/auth.test.ts` for the test contract.

## Provisioning the credentials

Before each App Review submission:

```bash
cd server/auth
echo "apple-reviewer-2026-04@heyblip.au" | npx wrangler secret put REVIEWER_EMAIL
echo "123456" | npx wrangler secret put REVIEWER_OTP
```

**Choose a fresh email per submission** (e.g. include the year-month) so credentials from a previous review can't be replayed. Choose a non-trivial 6-digit OTP. After the review concludes, **rotate immediately**:

```bash
npx wrangler secret delete REVIEWER_EMAIL
npx wrangler secret delete REVIEWER_OTP
```

Deleting the secrets disables the bypass entirely. The reviewer credentials only live for the duration of the review window — typically 1–3 days for a new submission, longer for resubmissions.

## App Store Connect submission notes — paste-ready template

Paste the following into App Store Connect → My Apps → HeyBlip → App Information → App Review Information → Notes (or the closest equivalent field in the current ASC UI). Fill in the placeholders.

```
HeyBlip is a Bluetooth-mesh chat app for events (festivals, concerts, sporting events). The app uses BLE peer-to-peer + an optional WebSocket relay for off-mesh delivery. End-to-end encryption is via Noise XX + Ed25519 signatures.

DEMO ACCOUNT (bypasses email OTP — no SMS / email is sent)
Email: <REVIEWER_EMAIL>
OTP code: <REVIEWER_OTP>

Steps to sign in:
1. Launch the app.
2. On the welcome screen, tap "Get Started".
3. Enter <REVIEWER_EMAIL> in the email field, tap Continue.
4. The next screen asks for a 6-digit code. NO EMAIL IS SENT — this account bypasses OTP. Enter <REVIEWER_OTP>, tap Verify.
5. Pick any username (e.g. "appletester"), tap Continue.
6. Grant Bluetooth + Microphone + Notifications when prompted (Bluetooth is required; the others are optional). Tap "Get started".
7. You are now signed in. The app opens to the Nearby tab.

WHAT TO TRY
- Add a friend: Tap the Nearby tab → Add Friend → enter "demo-friend-1" → tap Add. (You'll see a pending request — friend acceptance requires the other side, which isn't pre-seeded for this v1 bypass.)
- Open settings: Profile tab → Settings. The "Help & Support" link goes to https://heyblip.au/support which is the public support page (App Store Guideline 1.2 contact info).
- Block / report flow: Tap any incoming message bubble → long-press → Report (currently visible only when the report wiring is live; today the in-app report path goes through abuse@heyblip.au by email).
- SOS: Hold the SOS button on the main screen for 2s to see the SOS confirmation flow. Cancel before sending — the test environment doesn't have responders.

WHAT NOT TO TRY
- Do not register additional accounts using the demo OTP — the bypass is scoped to one specific email. Other emails go through real OTP delivery via Resend, which works for legitimate users but is not part of the demo flow.
- The App Privacy nutrition label declares what the production app collects. The demo account stores the same data.

DATA / PRIVACY
- All message content is end-to-end encrypted via Noise XX. The server never sees plaintext.
- The relay buffers offline-recipient packets briefly (max 1hr / 50 packets per peer) for store-and-forward delivery. This is declared in the App Privacy section.
- Account deletion: Profile → Settings → Account → Delete Account immediately removes the account from the registry.

SUPPORT CONTACT
- General: support@heyblip.au
- Safety / abuse: abuse@heyblip.au
- Privacy: privacy@heyblip.au
- Web: https://heyblip.au/support
```

Replace `<REVIEWER_EMAIL>` and `<REVIEWER_OTP>` with the actual values you provisioned via wrangler secret. The reviewer reads the Notes field directly — keep it scannable.

## Pre-seeded account state — known gap (v1 limitation)

The full BDEV-366 spec calls for the reviewer account to be pre-seeded with 2–3 friends, 1–2 active DMs, and a joined event so the app surfaces aren't empty. **This v1 implementation does NOT pre-seed.** The reviewer sees an empty Nearby list, empty chat list, and empty events list.

Reasons:
- Pre-seeding requires creating multiple test accounts whose Noise public keys are known server-side. The server can't generate keys for those accounts (they're client-generated and stored in the Keychain).
- Pre-built friend graphs require per-test-account DB rows + signed friend-request packets that the reviewer's device would need to process on first sync. That's a meaningful amount of plumbing and risk.

**Mitigation in the submission notes (above):** explicit "What to try" steps that walk the reviewer through actually using the friend-add flow, even from an empty state. Apple's reviewers are accustomed to empty states for messaging apps; the friend-add UX is what they grade, not the pre-existing friend list.

If a future review pass requires a non-empty initial state, file a follow-up ticket scoped specifically to "pre-seed reviewer account with N test friends + M test DMs". Will require a one-shot seed script that registers the support accounts + signs synthetic friend-accept packets.

## Security considerations

- The bypass is **per-email-match only** — a misconfigured `REVIEWER_EMAIL` doesn't accidentally bypass for arbitrary users.
- The bypass requires BOTH env vars present — partial config is fail-safe.
- The bypass logs a `console.info` line (`[auth] reviewer OTP bypass — no email sent`) so usage is visible in `wrangler tail`. Watch for unexpected hits there during a review window.
- After review: **delete both secrets immediately**. Leaving them set indefinitely means a known-OTP login path stays open for the configured email.
- **Never commit the actual values to git.** They live in:
  - Cloudflare Worker secrets (`wrangler secret put`)
  - App Store Connect submission notes (Apple-internal, not publicly visible)

## Test contract

`server/auth/test/auth.test.ts` covers:

- Reviewer email returns `sent: true` without dispatching email
- KV stores the configured reviewer OTP, not a randomly generated one
- No rate-limit entry recorded (reviewer can re-send freely)
- `/v1/auth/verify-code` accepts the OTP through the standard path
- Match is case-insensitive
- Non-reviewer emails fall through to the normal flow
- Bypass is OFF when `REVIEWER_EMAIL` is unset
- Bypass is OFF when `REVIEWER_OTP` is unset

## Related

- [BDEV-360](https://heyblip.atlassian.net/browse/BDEV-360) — anonymous-chat defence (referenced in submission notes above)
- [BDEV-361](https://heyblip.atlassian.net/browse/BDEV-361) — moderation process (referenced via `support@heyblip.au` in submission notes)
- [BDEV-363](https://heyblip.atlassian.net/browse/BDEV-363) — `/support` page (public landing for reviewer's contact link)
- [BDEV-365](https://heyblip.atlassian.net/browse/BDEV-365) — App Privacy nutrition label (must agree with this submission notes content)
- [BDEV-419](https://heyblip.atlassian.net/browse/BDEV-419) — branded verification email (the email the bypass skips)
