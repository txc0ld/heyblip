# John's Manual Launch-Prep Steps

**Audience:** John only
**Last reviewed:** 2026-04-27

Five manual tasks that need your hands. Each is independent — do them in any order. Total time across all five: ~2.5 hours.

## Quick index

| # | Task | Where | Time |
|---|---|---|---|
| 1 | [Email aliases](#1-email-aliases) | Cloudflare Email Routing | ~10 min |
| 2 | [Reviewer OTP secrets](#2-reviewer-otp-secrets) | Terminal (wrangler) | ~5 min |
| 3 | [App Privacy nutrition label](#3-app-privacy-nutrition-label) | App Store Connect | ~30 min |
| 4 | [App Store screenshots](#4-app-store-screenshots) | Xcode Simulator | ~60 min |
| 5 | [Jira Verifying gate](#5-jira-verifying-gate) | Atlassian admin | ~15 min |

---

## 1. Email aliases

You need four public-facing aliases live before App Store submission: `abuse@`, `support@`, `privacy@`, `hello@heyblip.au`. All four route to **John, Tay, and Fabian** so any one of you can pick up.

This is also tracked in [BDEV-430](https://heyblip.atlassian.net/browse/BDEV-430) (assigned to Tay). If Tay ships it first, skip this section and just verify the aliases work (steps 6–7 below). If you're doing it yourself, follow the full recipe.

### Prerequisites
- Cloudflare account access to the `heyblip.au` domain (the one running the website at https://heyblip.au)
- Tay's and Fabian's personal email addresses

### Steps

1. **Open Cloudflare Email Routing**
   👉 https://dash.cloudflare.com/?to=/:account/:zone/email/routing/routes
   (or: dash.cloudflare.com → pick `heyblip.au` from the domain list → Email → Email Routing → Routes)

2. **Verify Email Routing is enabled.** Top of the page should say "Email Routing enabled". If not, click "Enable Email Routing" first — Cloudflare walks you through verifying the MX records on your `heyblip.au` zone (takes 5 min the first time, zero if already done).

3. **Add the destination addresses.** This is one-time setup. Cloudflare needs to verify each destination before you can route to it.
   - Go to the **Destination addresses** tab.
   - Click **Add destination address**.
   - Add each of: your personal email, Tay's email, Fabian's email. Each gets a verification email — click the link in their inbox to confirm.

4. **Create the four routing rules.** Routes tab → **Create address**. For each alias:

   | Custom address | Action | Destination |
   |---|---|---|
   | `abuse@heyblip.au` | Send to an email | (one route per destination — see note below) |
   | `support@heyblip.au` | Send to an email | (same) |
   | `privacy@heyblip.au` | Send to an email | (same) |
   | `hello@heyblip.au` | Send to an email | (same) |

   **Cloudflare Email Routing limit:** one rule = one destination address. To fan out to all three of you, the simplest path is **three rules per alias** (one rule routing `abuse@heyblip.au` to John, another routing `abuse@heyblip.au` to Tay, another to Fabian). 12 rules total.
   - Cloudflare collapses identical sources in the UI; it's not as messy as it sounds.
   - Alternative if you want to avoid 12 rules: deploy a tiny Worker that takes one address and forwards to all three. Out of scope for this doc — 12 rules is fine for v1.

5. **Save each rule.** Cloudflare applies them within ~30 seconds.

6. **Test send.** From your phone (or any external email account), send a test email to each of `abuse@`, `support@`, `privacy@`, `hello@heyblip.au`. Subject: "test" is fine.

7. **Verify all three of you receive it.** Within 5 minutes you, Tay, and Fabian should each see the test email in your inbox. If anyone is missing, recheck the destination verification step (step 3).

### Done when

- ✅ Test email to each of the 4 aliases delivers to all 3 of your inboxes within 5 min.
- ✅ Comment "live" on [BDEV-430](https://heyblip.atlassian.net/browse/BDEV-430).

---

## 2. Reviewer OTP secrets

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
