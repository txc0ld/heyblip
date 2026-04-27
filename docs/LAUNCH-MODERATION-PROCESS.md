# Moderation & Abuse-Response Process

**Audience:** App Store Reviewer + internal HeyBlip team
**Ticket:** [BDEV-361](https://heyblip.atlassian.net/browse/BDEV-361)
**Last reviewed:** 2026-04-27

This document is the public-facing moderation policy for HeyBlip and the operational process behind it. It satisfies App Store Guideline 1.2 (Safety — User-Generated Content) requirements that user-generated content services must provide:

1. A method for filtering objectionable material.
2. A mechanism to report offensive content.
3. The ability to block abusive users.
4. Contact information for support.
5. Action taken against bad actors and content within 24 hours.

## Public contact

| Purpose | Email |
|---|---|
| Abuse / safety reports | **abuse@heyblip.au** |
| General support | **support@heyblip.au** |
| Web support page | https://heyblip.au/support |

These addresses route to the HeyBlip team. Reports submitted to **abuse@heyblip.au** are triaged within **72 hours**; urgent safety concerns (threats of physical violence, child safety) are escalated immediately on receipt and may be referred to law enforcement.

## What we moderate

HeyBlip is a peer-to-peer encrypted chat platform. We do not have access to the plaintext content of direct messages or group messages — they are end-to-end encrypted via Noise XX. We can moderate based on:

1. **Reports submitted by users**, which include the report context (a user identifier and, optionally, the user's own copy of the content they are reporting).
2. **Account-level signals visible to the registry** — cryptographic identity, registration metadata, server logs of authentication / relay activity.
3. **Public-facing surfaces** — group channel names, event channel names, usernames, profile bios. We do moderate these.

We do not moderate the plaintext content of E2E DMs or group messages. We rely on the recipient's report-and-block flow to surface abuse.

## Moderation actions available

| Action | Effect | Reversible? |
|---|---|---|
| **Warn** | Email to the registered address; logged. | n/a |
| **Mute** (server-side) | Account can still authenticate but the relay will refuse to forward their messages. BLE-direct messages still flow but off-mesh delivery is suppressed. | Yes, by lifting the server-side flag. |
| **Suspend** | Account cannot authenticate. All sessions invalidated. Visible in the mesh as offline. | Yes, by clearing the suspension. |
| **Revoke** (permanent ban) | Public key marked as revoked in the registry. Account cannot re-authenticate. The user is permanently barred from registering with the same email. | No (intentional). |
| **Remove from group / event channel** | Group/event admin actions. The user is removed from the channel and cannot rejoin without a new invite. | n/a (re-invite possible). |
| **Take down channel name / username / bio** | Server-side string updates. | n/a. |

## Reporting flow (today)

A user wishing to report another user or a piece of content has two paths:

1. **In-app block** — available from any user's profile sheet and from the Friends list. Blocking is immediate and unilateral; the blocked user cannot send messages, friend requests, or appear in the reporter's mesh peer list. (See `docs/LAUNCH-ANONYMOUS-CHAT-DEFENCE.md` for design notes.)

2. **Email report to abuse@heyblip.au** — the user includes:
   - Their own username (so we can verify the report is from a real account).
   - The reported user's username, or a screenshot showing the offensive content.
   - A short description of the concern.

   We acknowledge receipt within 24 hours and triage within 72 hours.

### In-app Report flow (planned, pre-launch)

Visual surfaces for in-app Report are already present on message bubbles (long-press → Report) and user profile sheets (Profile → Report). Server-side wiring of the Report flow to a moderation inbox is tracked under an outstanding engineering ticket and will be live before public App Store availability. Until then, reporting is handled via the email channel above.

Note for App Store review: the in-app Report buttons are conditionally rendered (`onReport != nil`) and are currently not visible to end users until the server-side wiring lands. This avoids presenting a non-functional UI during review.

## Triage process

When a report arrives at abuse@heyblip.au:

1. **Acknowledge receipt** within 24 hours via reply-email to the reporter.
2. **Verify** the reporter is a registered HeyBlip user (lookup by username/email).
3. **Assess severity:**
   - **Tier 1 (immediate response):** threats of physical violence, child safety concerns, doxxing, criminal solicitation. Escalated within 24 hours; may include law-enforcement referral.
   - **Tier 2 (72-hour response):** harassment, hate speech, spam, scam attempts, clear policy violations. Action taken within 72 hours.
   - **Tier 3 (best-effort):** policy edge cases, "this person is annoying me" without clear violation. Counselled to use block; no server-side action unless escalates to Tier 2.
4. **Investigate:**
   - Pull server logs for the reported account (authentication times, registration metadata, relay activity).
   - If the report includes E2E content (e.g. screenshot from the recipient), verify against signature metadata where possible.
   - If the report concerns a public-facing string (channel name, username, bio), inspect directly.
5. **Decide and act:** apply the appropriate moderation action from the table above. Log the decision.
6. **Notify the affected user** via email to their registered address. Include the reason and (where applicable) the appeal path.
7. **Notify the reporter** with a brief outcome ("we have actioned the report" / "we did not find a policy violation, please use block").

## Appeals

A user who has been muted, suspended, or revoked can appeal by emailing **abuse@heyblip.au** within 30 days. Appeals are reviewed by a different team member than the one who issued the action. Appeal decisions are final.

A user whose account has been **revoked** for a Tier 1 violation has no appeal path. Revocation is intentional and permanent for safety reasons.

## Logging and retention

- **Moderation actions** are logged to a private, append-only log (cryptographic identity of the moderator + timestamp + action + brief reason).
- **Reports** are retained for 12 months from receipt, then deleted.
- **Appeals** are retained for 12 months from decision.
- **Server logs** (authentication, relay, push) are retained for 30 days for operational and abuse investigation purposes; see HeyBlip's privacy policy for full data-handling detail.

## Filtering automated / spam content

HeyBlip applies the following automated filters:

1. **Registration rate limiting** — accounts cannot be registered faster than a threshold per source IP / per email domain. Currently being tuned under [BDEV-416](https://heyblip.atlassian.net/browse/BDEV-416).
2. **Cryptographic challenge** on registration — only a holder of a fresh Ed25519 keypair can complete registration ([BDEV-183](https://heyblip.atlassian.net/browse/BDEV-183), shipped). This blocks naive scripted registration.
3. **Sender PeerID verification on the relay** — the relay rejects messages where the sender PeerID does not match the authenticated WebSocket connection. This stops spoofing attacks.
4. **Per-peer message rate limiting** at the relay layer (queued packets are bounded; overflow is dropped).

Content filtering of E2E plaintext is not technically possible without breaking E2E. We rely on the report-and-block flow described above.

## Policy violations — non-exhaustive list

The following are grounds for moderation action under HeyBlip's terms of service:

- Threats of physical violence against any person.
- Child sexual abuse material (CSAM) — zero tolerance, immediate revocation, law-enforcement referral.
- Doxxing (publishing private personal information of another user without consent).
- Coordinated harassment campaigns.
- Hate speech targeting protected attributes (race, religion, gender identity, sexual orientation, disability).
- Spam, including scam links, promotional content, or repeated unsolicited DMs.
- Impersonation of a specific real person.
- Coordinated inauthentic behaviour (multi-account abuse, sockpuppeting).
- Use of HeyBlip to facilitate illegal activity (drug trafficking, fraud, etc.).

## Working with law enforcement

HeyBlip cooperates with valid legal process. Law-enforcement requests should be directed to **abuse@heyblip.au** with the subject line "LEA REQUEST". We respond with the metadata available — registration email, registration timestamp, public keys, relay session metadata, IP addresses where logged — within statutory response windows, subject to verification of the request's authenticity.

We do **not** have access to E2E plaintext message content. We do **not** retain message content on the relay beyond the store-and-forward TTL (1 hour, 50 packets per peer cap). We will state this clearly in any response.

## Team

The HeyBlip team is small (founder + frontend engineer + marketing). Moderation is handled by the founder during the early phase, with on-call coverage during peak usage windows. As HeyBlip scales, dedicated moderation capacity will be added.

## Public statement of policy

The plain-English version of this policy is available at https://heyblip.au/support and will be referenced from inside the app via the Settings → Help screen before public App Store availability.
