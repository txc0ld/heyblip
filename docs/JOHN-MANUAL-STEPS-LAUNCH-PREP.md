# John's Manual Launch-Prep Steps

**Audience:** John only
**Last reviewed:** 2026-04-28

Five manual tasks that need your hands. Each is independent — do them in any order. Total time across all five: ~2.5 hours.

## Quick index

| # | Task | Where | Time | Status |
|---|---|---|---|---|
| 1 | [Email aliases](#1-email-aliases) | Porkbun Email Forwarding | ~5 min | active |
| 2 | [Reviewer OTP secrets](#2-reviewer-otp-secrets) | Terminal (wrangler) | ~5 min | ✅ DONE 2026-04-28 |
| 3 | [App Privacy nutrition label](#3-app-privacy-nutrition-label) | App Store Connect | ~30 min | active |
| 4 | [App Store screenshots](#4-app-store-screenshots) — **ON HOLD** | Xcode Simulator | ~60 min | paused |
| 5 | [Jira Verifying gate](#5-jira-verifying-gate) | Atlassian admin | ~15 min | active |

**Active total** (excluding screenshots + #2): ~50 min across the 3 remaining active tasks.

---

## 1. Email aliases

You need four public-facing aliases live before App Store submission: `abuse@`, `support@`, `privacy@`, `hello@heyblip.au`. All four forward to **John, Tay, and Fabian** so any one of you can pick up.

The `heyblip.au` domain is registered with **Porkbun**, and email is handled by **Porkbun's free Email Forwarding** (verified via DNS: MX → `fwd1.porkbun.com` / `fwd2.porkbun.com`, SPF → `_spf.porkbun.com`, nameservers → `*.ns.porkbun.com`). Porkbun's forwarding supports up to **6 destinations per forward rule**, so we can fan out to all three of you with a single rule per alias.

This is also tracked in [BDEV-430](https://heyblip.atlassian.net/browse/BDEV-430) (assigned to Tay — he handles email infra). If Tay ships it first, skip the setup steps and just verify the aliases work via the test-send (step 5 below).

### Prerequisites
- Porkbun account credentials for the account that owns `heyblip.au`
- Tay's and Fabian's personal email addresses
- A few minutes — Porkbun applies forwards within seconds, no DNS propagation wait

### Steps

1. **Open Porkbun's domain management for heyblip.au:**
   👉 https://porkbun.com/account/domainsSpeedy
   Sign in if needed. Find `heyblip.au` in the domain list.

2. **Open Email Forwarding for the domain.**
   - Click the **Details** button next to `heyblip.au`.
   - Scroll to the **Email Forwarding** section.
   - Or go direct: 👉 https://porkbun.com/account/email/heyblip.au

3. **Check what already exists.** Some aliases (`verify@` for the Resend FROM address, `support@`, `privacy@`) may already be set up. List them. If any of the four required ones (`abuse@`, `support@`, `privacy@`, `hello@`) are already there:
   - **Edit** the existing forward to make sure it routes to all three of you (John + Tay + Fabian).
   - Skip step 4 for that alias.

4. **Add or update the four forwards.** Click **Add Forward** for each missing alias:

   | Custom address | Forwards to (comma-separated, up to 6) |
   |---|---|
   | `abuse@heyblip.au` | `<your-personal-email>, <tay-email>, <fabian-email>` |
   | `support@heyblip.au` | (same three) |
   | `privacy@heyblip.au` | (same three) |
   | `hello@heyblip.au` | (same three) |

   Porkbun's forward UI accepts a comma-separated list of destinations in a single forward rule. **One rule per alias, three destinations each.** No verification step on the destination side — Porkbun trusts the address you type.

5. **Test send.** From your phone (or any external email account), send a test email to each of `abuse@`, `support@`, `privacy@`, `hello@heyblip.au`. Subject: "test" is fine.

6. **Verify all three of you receive it.** Within 5 minutes you, Tay, and Fabian should each see the test email in your inbox. If anyone is missing, double-check the comma-separated list in the forward rule for typos.

### Note on `verify@heyblip.au`

Don't touch the `verify@heyblip.au` alias if it already exists — Resend uses it as the *FROM* address when sending OTP emails to users (see `server/auth/wrangler.toml`'s `FROM_EMAIL`). It doesn't need to forward anywhere; it just needs to exist as a valid sender on the domain. If for some reason you need to set it up: forward to `/dev/null` equivalent (Porkbun lets you forward to any destination — pick one of yours, ignore replies, or leave it unforwarded if Porkbun allows existing-but-unforwarded).

### Done when

- ✅ Test email to each of the 4 aliases delivers to all 3 of your inboxes within 5 min.
- ✅ Comment "live" on [BDEV-430](https://heyblip.atlassian.net/browse/BDEV-430) with which aliases got created vs which were already there.

---

## 2. Reviewer OTP secrets

> **✅ COMPLETED 2026-04-28 ~05:21 AWST** — secrets armed in the post-EOD `blip-auth` redeploy. Latest deployed version: `e75d026d`. Reviewer can sign in with `apple-reviewer-2026-04@heyblip.au` + OTP `846291`. Smoke-test confirmed (`POST /v1/auth/send-code` returns `{"sent":true}` without sending an email). The steps below are kept as historical reference + for the **rotation step after App Review concludes**.

Set the reviewer OTP-bypass secrets on the `blip-auth` Cloudflare Worker so Apple's reviewer can sign in without going through real email-OTP infrastructure. Companion to PR [#294](https://github.com/txc0ld/heyblip/pull/294) (which adds the bypass code).

### Prerequisites
- PR #294 merged (the bypass branch needs to exist in production)
- `wrangler` CLI logged in to the right account (`john_mckean@hotmail.com` per the boot file)

### Steps

1. **Pick the reviewer email + OTP.** Use a fresh email per submission so old credentials can't be replayed:
   - Email: `apple-reviewer-2026-04@heyblip.au` (vary the year-month each submission)
   - OTP: any 6-digit number you'll remember, e.g. `846291`

2. **Open Terminal** and `cd` to `~/heyblip/server/auth/`.

3. **Set the email secret:**
   ```bash
   echo "apple-reviewer-2026-04@heyblip.au" | npx wrangler secret put REVIEWER_EMAIL
   ```

4. **Set the OTP secret:**
   ```bash
   echo "846291" | npx wrangler secret put REVIEWER_OTP
   ```

5. **Verify both secrets are set:**
   ```bash
   npx wrangler secret list
   ```
   You should see `REVIEWER_EMAIL` and `REVIEWER_OTP` in the list (values are not printed — that's expected).

6. **Smoke-test from your phone or simulator on a test build** (post-merge of PR #294):
   - Open the app
   - Sign-up flow → enter `apple-reviewer-2026-04@heyblip.au`
   - Wait for the OTP screen — **no email is sent** (this is the bypass)
   - Enter `846291`
   - You should be onboarded successfully

### After App Review concludes

**Rotate immediately** — do not leave the bypass active indefinitely:

```bash
cd ~/heyblip/server/auth
npx wrangler secret delete REVIEWER_EMAIL
npx wrangler secret delete REVIEWER_OTP
```

Bypass is now OFF. Next submission needs a fresh pair (step 1).

### Done when

- ✅ `wrangler secret list` shows both `REVIEWER_EMAIL` and `REVIEWER_OTP`
- ✅ Smoke-test sign-up via reviewer email succeeds without an email being sent
- ✅ Reminder set somewhere (calendar / notes) to rotate the secrets after review

---

## 3. App Privacy nutrition label

Paste the per-category answers from `docs/LAUNCH-APP-PRIVACY-DECLARATION.md` (PR [#295](https://github.com/txc0ld/heyblip/pull/295)) into App Store Connect. The doc has the full answers; this section is the click path.

### Prerequisites
- App Store Connect access (Apple Developer account)
- Privacy policy live at https://heyblip.au/privacy (already live)
- HeyBlip listing already created in App Store Connect (any state — even draft)

### Steps

1. **Open App Store Connect**
   👉 https://appstoreconnect.apple.com/apps
   Sign in with the Apple ID that owns the HeyBlip listing.

2. **Open the HeyBlip app listing.**

3. **Navigate to App Privacy.**
   - Left sidebar → **App Privacy** (under "App Information").
   - If not yet started, you'll see "Get Started". Click it.

4. **Set the privacy policy URL.** First field at the top:
   - Privacy Policy URL: `https://heyblip.au/privacy`

5. **Open the spec doc in another tab:**
   👉 [docs/LAUNCH-APP-PRIVACY-DECLARATION.md](LAUNCH-APP-PRIVACY-DECLARATION.md)
   This has the per-category answers.

6. **Walk through the data-type categories.** App Store Connect presents categories one at a time. For each, the spec doc tells you whether to declare YES or NO and (if YES) the linked-to-user / tracking / purpose answers.

   Quick summary you can scan against the UI:
   - **Contact Info → Email Address** → YES, linked, not tracking, App Functionality
   - **Identifiers → User ID** → YES, linked, not tracking, App Functionality + Account Creation
   - **Identifiers → Device ID** → NO
   - **User Content → Messages** → YES, linked, not tracking, App Functionality
   - **User Content → Photos / Videos** → YES, linked, not tracking, App Functionality
   - **User Content → Audio Data** → YES, linked, not tracking, App Functionality
   - **User Content → Customer Support** → NO
   - **User Content → Other** → NO
   - **Location → Coarse** → YES, linked, not tracking, App Functionality
   - **Location → Precise** → YES, linked, not tracking, App Functionality
   - **Diagnostics → Crash Data** → YES, linked, not tracking, App Functionality + Analytics
   - **Diagnostics → Performance Data** → YES, linked, not tracking, App Functionality + Analytics
   - **Diagnostics → Other** → NO
   - **Usage Data** → all NO
   - **Purchases → Purchase History** → YES, linked, not tracking, App Functionality
   - **Health & Fitness, Financial Info, Sensitive Info, Contacts, Browsing History, Search History, Other Data** → all NO

7. **Tracking declaration.** App Store Connect asks "Do you or your third-party partners use data from this app to track users?" → **No**.

8. **Save.** ASC lets you save and come back; you don't have to finish in one sitting.

9. **Verify the summary card** matches:
   - Data linked to you: Email, User ID, Messages, Photos / Videos, Audio Data, Coarse + Precise Location, Crash + Performance Data, Purchase History
   - Data not linked to you: (none)
   - Data used to track you: (none)

### Done when

- ✅ App Privacy section in ASC shows green "Ready to Submit" status
- ✅ Privacy Policy URL field set to `https://heyblip.au/privacy`
- ✅ Summary card matches step 9

---

## 4. App Store screenshots

> ⏸️ **ON HOLD — capture when the app is at its final-candidate build.**
>
> Decision (2026-04-27): the app UI is still evolving (Tay's frontend polish sprint — BDEV-422/423/424/425/426/427 — is mid-flight; Build 44 is the latest TestFlight cut). Capturing screenshots now means re-doing them after every meaningful UI change. Defer until the build that's going to App Review.
>
> **Trigger to pick this back up:** when the build that's going to be submitted is identified — typically when there are no open frontend-polish PRs for the screens being captured (chat list, friend finder, events, SOS, friend-add, onboarding) and Tay/Fabian have signed off on the visuals.
>
> Ticket [BDEV-364](https://heyblip.atlassian.net/browse/BDEV-364) is back in **To Do**. The recipe below stays in place so you can run it cold once the trigger fires.

Capture 12 PNGs (6 shots × 2 device classes) for the App Store listing. Full spec at `docs/LAUNCH-APP-STORE-SCREENSHOTS.md` (PR [#295](https://github.com/txc0ld/heyblip/pull/295)). This section is the streamlined click path.

### Prerequisites
- Xcode + iOS 17+ simulators installed
- A Release build of HeyBlip running in the simulator (debug overlay OFF — verified by PR [#290](https://github.com/txc0ld/heyblip/pull/290) BDEV-362)
- The reviewer demo account (item #2 above) live, or a real test account you've signed in with

### Steps

1. **Boot both simulators.** Xcode → Window → Devices and Simulators → Simulators tab. Boot:
   - **iPhone 17 Pro Max** (or 16 Pro Max if 17 not yet available)
   - **iPad Pro 13-inch (M4)**

2. **Set the status bar to Apple's editorial preset on each simulator.** Open Terminal:

   ```bash
   xcrun simctl status_bar "iPhone 17 Pro Max" override \
     --time "9:41" \
     --dataNetwork wifi --wifiMode active --wifiBars 3 \
     --cellularMode active --cellularBars 4 \
     --batteryState charged --batteryLevel 100

   xcrun simctl status_bar "iPad Pro 13-inch (M4)" override \
     --time "9:41" \
     --dataNetwork wifi --wifiMode active --wifiBars 3 \
     --cellularMode active --cellularBars 4 \
     --batteryState charged --batteryLevel 100
   ```

   Adjust simulator names to match `xcrun simctl list devices` if they differ.

3. **Make a directory to drop screenshots in:**
   ```bash
   mkdir -p ~/heyblip-screenshots/{iphone-6.9,ipad-13}
   cd ~/heyblip-screenshots
   ```

4. **For each of the 6 shots, on each simulator:**

   | Shot | What to show |
   |---|---|
   | `01-mesh-discovery.png` | Nearby tab — peer list with 3-5 entries, mix of friends + strangers |
   | `02-encrypted-dm.png` | Chat thread mid-conversation, sender name + verified badge, 4-6 bubbles, no PII |
   | `03-events-tab.png` | Events tab — 2-3 event cards |
   | `04-sos-flow.png` | SOS confirmation sheet mid-press (cancel before send) |
   | `05-friend-add.png` | Add Friend sheet with QR code prominent |
   | `06-onboarding.png` | Onboarding step 1 (WelcomeStep) hero illustration |

   For each: navigate the app to the right state, then run:
   ```bash
   # iPhone
   xcrun simctl io "iPhone 17 Pro Max" screenshot --type png ~/heyblip-screenshots/iphone-6.9/01-mesh-discovery.png

   # iPad
   xcrun simctl io "iPad Pro 13-inch (M4)" screenshot --type png ~/heyblip-screenshots/ipad-13/01-mesh-discovery.png
   ```

5. **Pre-flight checklist for each capture** (re-verify before each):
   - Status bar shows 9:41, full bars, full battery
   - No notification banner currently visible
   - No debug overlay visible (triple-tap test confirms gate is working in Release)
   - No PII visible — sample data only
   - No spinners / loading states

6. **Open ASC → My Apps → HeyBlip → App Store → Media → Screenshots:**
   👉 https://appstoreconnect.apple.com/apps

7. **Upload:**
   - Pick **iPhone 6.9" Display** in the device picker → drag all 6 PNGs from `~/heyblip-screenshots/iphone-6.9/`, in order.
   - Pick **iPad Pro 13" Display** → drag the iPad set.
   - Save.

### Done when

- ✅ 12 PNGs captured, opened, eyeballed for status-bar correctness + no PII + no debug overlay
- ✅ Uploaded to App Store Connect at iPhone 6.9" + iPad 13"

---

## 5. Jira Verifying gate

Enable the **Verifying** workflow status in BDEV so PR-merged tickets sit in a verification phase before being marked Done. Full recipe at `docs/PROCESS-VERIFICATION-GATE-JIRA-SETUP.md` (PR [#295](https://github.com/txc0ld/heyblip/pull/295)). This section is the streamlined version.

### Prerequisites
- Atlassian admin access on https://heyblip.atlassian.net (you have it — `macca.mck@gmail.com`)
- BDEV project workflow currently looks like: To Do → In Progress → Done

### Steps

1. **Add the `Verifying` status (global):**
   👉 https://heyblip.atlassian.net/jira/settings/issues/statuses
   - Click **Add status**
   - Name: `Verifying`
   - Category: `In Progress` (yellow)
   - Description: `Awaiting on-device verification or smoke test before transitioning to Done. Set automatically by the GitHub merge automation rule; cleared by a verification comment.`
   - Click **Create**

2. **Attach to the BDEV workflow:**
   👉 https://heyblip.atlassian.net/jira/settings/issues/workflows
   - Find the BDEV workflow (probably "BDEV: Software Simplified" or similar). Click it → **Edit** (diagram view).
   - Click **Add status** in the toolbar → pick `Verifying` → drop on canvas between In Progress and Done.
   - Drag transitions:
     - From **In Progress → Verifying**, name `Mark verifying`
     - From **Verifying → Done**, name `Mark verified`
     - From **Verifying → In Progress**, name `Reopen for fix`
     - From **In Progress → Done**, name `Done (no device verification)` (this is the audited skip path)
   - Click **Publish workflow**. When asked about migration, pick **Don't migrate** (existing tickets stay where they are).

3. **Add the comment validator on `Mark verified`:**
   - Re-open the workflow → click the `Mark verified` transition arrow.
   - **Validators tab → Add validator → Regular Expression Check**
   - Field to validate: `Comment`
   - Regular expression: `(?i)(build [a-f0-9]{6,}|\b[a-f0-9]{7,40}\b|skip:|build \d+|deployed|smoke[ -]?trace)`
   - Error message: `Verifying → Done requires a comment with one of: a commit hash, a build SHA, "skip: <reason>", a deployment URL, or "smoke trace passed".`
   - Save → **Publish workflow** again.

4. **Add the GitHub-merge automation rule:**
   👉 https://heyblip.atlassian.net/jira/settings/automation
   - Click **Create rule**
   - Trigger: **Branch merged** (provided by the GitHub-Jira integration)
   - Conditions:
     - PR title or branch contains regex `BDEV-\d+`
     - Issue status is `In Progress`
   - Action 1: **Transition issue** → `Mark verifying`
   - Action 2: **Add comment** with body:
     ```
     Auto-transitioned to Verifying on merge of {{pullRequest.url}}. Verification comment required for transition to Done — include a commit SHA, build number, smoke-trace note, or "skip: <reason>".
     ```
   - Save → enable rule.

5. **Add the audit-trail label on the skip path:**
   - Re-open the workflow → click the `Done (no device verification)` transition arrow.
   - **Post-functions tab → Add post-function → Update Issue Field**
   - Field: `Labels`
   - Value: `done-no-device-verification`
   - Save → **Publish workflow**.

6. **Smoke test with one PR.** Pick a low-risk ticket currently In Progress (e.g. one of today's PRs once merged). Confirm:
   - On merge, ticket auto-transitions to Verifying ✓
   - Auto-comment posts ✓
   - Trying to transition to Done without a comment → error ✓
   - Adding a comment with a commit SHA → transition succeeds ✓

7. **After smoke test passes, update `CLAUDE.md`** with the new engineer-agent rule. Open `~/heyblip/CLAUDE.md`, find the line:
   > Engineer-agents may transition Jira `To Do → In Progress`, never to Done.

   Replace with:
   > Engineer-agents may transition Jira `To Do → In Progress`, never to `Verifying` or `Done`. `In Progress → Verifying` is owned by the GitHub merge automation. `Verifying → Done` requires a verification comment and is owned by PM/Cowork. `Done (no device verification)` skip path is for CI / docs / refactor / observability — anything user-facing or transport must go through Verifying.

   Commit on a small follow-up PR.

### Done when

- ✅ Verifying status visible in BDEV workflow
- ✅ Test PR merge auto-transitions In Progress → Verifying
- ✅ Comment validator blocks Verifying → Done without verification comment
- ✅ CLAUDE.md updated with the new engineer-agent rule

### Rollback (if anything goes weird)

Atlassian's workflow editor has **Discard draft** before publish. After publish, re-edit the workflow → delete the Verifying status node + its transitions → republish. The automation rule can be disabled with one toggle without touching the workflow.

---

## When you're done with all 5

Comment "live" on each of the corresponding tickets:
- BDEV-430 (email aliases) — comment "all four aliases live"
- BDEV-366 (reviewer OTP) — comment with the email/OTP pair you provisioned (just for record — this is internal-only)
- BDEV-365 (App Privacy) — comment "submitted"
- BDEV-364 (screenshots) — comment "uploaded"
- BDEV-378 (Verifying gate) — comment "live, smoke-tested with PR #N"

Then ping me in `#blip-dev` and we'll cut Build 45 + push the App Store submission.
