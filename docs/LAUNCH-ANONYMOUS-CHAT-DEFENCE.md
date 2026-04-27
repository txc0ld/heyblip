# Anonymous-Chat Defence — App Store Reviewer Notes

**Audience:** App Store Reviewer
**Ticket:** [BDEV-360](https://heyblip.atlassian.net/browse/BDEV-360)
**Last reviewed:** 2026-04-27

This document anticipates the standard reviewer challenge for any chat application: *"This app permits anonymous user-to-user communication and may be used for harassment, abuse, or illegal activity."* The argument below explains why HeyBlip's design materially differs from the apps Apple's Guideline 1.2 is targeting, and what safeguards apply.

## TL;DR

HeyBlip is **not anonymous**. Every user holds a cryptographic identity bound to an email address and a unique username, and every message is signed by that identity. Direct messages require **mutual friend acceptance** before any content can be exchanged. There is **no global feed**, **no stranger-DM surface**, and **no public profile lookup beyond friend-add by exact username**. Abuse can be cryptographically attributed and the offender's account can be revoked at the registry level.

## What HeyBlip is

A Bluetooth-mesh chat application designed for high-density gatherings (festivals, concerts, sporting events, ultra-marathons) where cellular service is overloaded or unavailable. Users connect to nearby peers via BLE and exchange messages directly, with an optional WebSocket relay for off-mesh delivery.

The use case is **friends finding and messaging each other at events** — not strangers messaging strangers.

## Identity model — pseudonymous, not anonymous

Every account is bound to:

1. **An email address** verified at registration via OTP (one-time code sent to inbox).
2. **An Ed25519 signing keypair** generated locally and stored in the iOS Keychain. The public key is uploaded to our identity registry.
3. **A unique username** (chosen at registration, can be searched by exact match by other users).
4. **A Curve25519 Noise XX keypair** for end-to-end encryption of direct messages.

Every message includes the sender's PeerID (derived from the signing public key) and is signed Ed25519. The signature is verifiable by any node on the mesh. **There is no way to send an unsigned, unauthenticated message** through the protocol.

This is the same identity model as Signal, iMessage, or any modern E2E-encrypted messenger — pseudonymous by design, but cryptographically attributable.

## Communication boundaries

HeyBlip has **no global broadcast surface**. The communication channels are:

1. **Direct messages (DMs).** Require both parties to mutually accept a friend request first. A user cannot DM another user they are not friends with. Friend requests can be accepted, declined, or blocked. A blocked user cannot send further requests.
2. **Group channels.** Invite-only. The group creator and admins control membership. A user can leave a group at any time.
3. **Event channels.** Tied to a geofenced event (e.g. a specific festival). Users physically present at the event can post; non-attendees cannot. Channel administrators (typically event organisers) have moderation tools (mute, remove).
4. **Local mesh broadcasts.** Limited to peers physically within Bluetooth range (~10–30m). These are presence beacons, not messages — they communicate only "I am here" with a username, not arbitrary content.

There is **no equivalent of a public Twitter/X feed, no Chatroulette-style random pairing, no "nearby strangers" message surface.**

## How abuse is bounded

| Concern | Why HeyBlip's design constrains it |
|---|---|
| Stranger-to-stranger harassment | Friend gating on DMs; no random pairing; no public profile discovery beyond exact username search |
| Pornographic / illegal content broadcast at scale | No global feed; group/event channels are moderated; no anonymous mass-DM capability |
| Coordinated inauthentic behaviour | Email-bound accounts (rate-limited registration); cryptographic identity on every message; server can revoke keys |
| Threats to specific individuals | All messages cryptographically signed, attributable to a real registered account; law-enforcement disclosure path is straightforward |
| Bullying via group chats | Block functionality (visible across all surfaces); group admins can remove members; users can leave any group instantly |

## Self-help tools available to users today

- **Block.** Available from any user's profile sheet (long-press a username → Profile → Block) and from the Friends list. A blocked user cannot send messages, friend requests, or be visible in the user's mesh peer list.
- **Decline / unfriend.** Friend requests can be declined; existing friendships can be ended at any time.
- **Leave group.** Any group/event channel can be exited unilaterally.
- **Mute notifications.** Per-conversation mute is available (no notifications without disconnecting).

## Account revocation (registry-level)

The HeyBlip identity registry (`blip-auth` Cloudflare Worker, Neon Postgres) holds the public Ed25519 keys for every registered account. When a user is determined to have violated terms, our backend can:

1. Mark the account as revoked. All future authentication attempts fail.
2. Refuse to upload further key material.
3. Refuse to relay messages to/from that account on the WebSocket relay.

A revoked user's existing in-flight messages on peer devices remain (we cannot remotely tamper with E2E content) but they cannot establish new sessions or be discovered by new peers.

This is the equivalent of a server-side ban. We retain the operational capability to do this on demand.

## Reporting and contact

A user-facing report mechanism via email is available immediately at **abuse@heyblip.au**. Reports are triaged by the HeyBlip team within 72 hours; see `docs/LAUNCH-MODERATION-PROCESS.md` for the full moderation policy.

In-app Report buttons are present on message bubbles and user profile sheets (visual surface complete; the wiring to a server-side report inbox is tracked under a separate engineering ticket and will be live before any public App Store availability).

## Public-facing safety information

- **General support:** support@heyblip.au
- **Abuse / safety reports:** abuse@heyblip.au
- **Web:** https://heyblip.au/support (in development under [BDEV-363](https://heyblip.atlassian.net/browse/BDEV-363) — live before launch)

## Comparable apps with similar identity models

The HeyBlip identity-and-communication model is materially the same as several apps already on the App Store:

- **Signal** — pseudonymous (phone number / username), E2E encrypted, no public feed, friend-gated DM-only.
- **WhatsApp** — phone-number-bound, no public feed.
- **Discord** — username-bound, friend-gated DMs, group channels with moderation.
- **iMessage** — Apple-ID-bound, friend-gated DMs.

HeyBlip differs in transport (Bluetooth mesh + relay rather than cellular/WiFi) but is materially identical in identity, gating, and abuse-handling posture.

## Engineering safeguards already shipped

- Ed25519 challenge-response on registration (cryptographically prevents fake-account spam: only a holder of a fresh keypair can complete registration).
- Server-side rate limiting on `/v1/auth/challenge` and registration endpoints (currently surfacing under [BDEV-416](https://heyblip.atlassian.net/browse/BDEV-416) — being tuned but operational).
- TLS certificate pinning on auth + relay endpoints ([BDEV-185](https://heyblip.atlassian.net/browse/BDEV-185), shipped).
- Sender PeerID verification on the relay (the WebSocket connection is bound to the authenticated PeerID; the relay rejects packets where the sender PeerID does not match).
- Noise XX session establishment for all DMs (forward secrecy + authenticated encryption).

---

For Apple's review team: please reach us at **support@heyblip.au** with any further questions about identity, abuse handling, or moderation. The team is small but responsive — questions are typically answered within one business day.
