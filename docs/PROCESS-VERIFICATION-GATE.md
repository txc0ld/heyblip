# Process — Verification gate between Merged and Done

**Audience:** John, Tay, Fabian, Cowork PM, all engineering agents
**Ticket:** [BDEV-378](https://heyblip.atlassian.net/browse/BDEV-378)
**Last reviewed:** 2026-04-27

## Why this exists

Multiple P0 tickets in the BDEV project have followed the same anti-pattern: a fix lands, ticket is marked Done at PR merge, and a later 2-device test reveals the fix didn't actually fix the bug (or exposed a related one). "Done" today reflects "the code merged" — not "the user-facing behaviour is verified working".

Concrete examples from the ticket history:

- Three commits within 24 hours all titled "fix(relay): reduce ping interval / recover handshakes on reconnect / fix log labels" (`f62f1ca`, `67448e5`, PR #228 `bf5a3b6`, 2026-04-17/18). The third still didn't actually recover handshakes — see BDEV-373's analysis of `resendPendingHandshakesAfterRelayReconnect` being structurally a no-op.
- **BDEV-318** marked Done 2026-04-17 → **BDEV-319** (identical summary, same handshake race) filed and resolved 2026-04-25.
- **BDEV-372** self-documents the pattern: *"the fix in BDEV-368 unblocked the path and exposed the latent secret drift."*

## What changes

A new Jira status — **Verifying** — sits between **In Progress** and **Done**.

```
To Do  →  In Progress  →  Verifying  →  Done
                              │
                              └──→  Done (no device verification)   [audited path]
```

### Workflow

1. **Engineer-agent picks up a ticket** → transitions To Do → In Progress.
2. **Engineer-agent opens a PR** → leaves the ticket in In Progress, posts the PR link in `#blip-dev`. *(No transition — that's John's merge step.)*
3. **John merges the PR** → Jira automation transitions the ticket to **Verifying** (not directly to Done).
4. **PM/Cowork or the assigned verifier** runs the verification — typically a 2-device test trace, smoke trace, deploy probe, or Sentry check on the next TestFlight build.
5. **Verifier comments on the ticket with the verification note**, then transitions Verifying → Done. The comment must include:
   - **Build SHA** (or commit hash) being verified
   - **Scope of the check** — what was actually exercised (e.g. "first DM after fresh install on Build 45 — banner appeared, push delivered, decryption clean")
   - **Outcome** — pass / fail / partial

### Skip path — no device verification needed

For tickets where on-device verification doesn't apply, a **Done (no device verification)** transition is available:

| Ticket type | Skip path applies? |
|---|---|
| CI / build config changes | Yes |
| Wiki / docs / process | Yes |
| Refactors with no behaviour change | Yes |
| Server-side bug fix verified by `npm test` + Sentry-resolved | Yes |
| Test infrastructure | Yes |
| **Anything user-facing** | **No** |
| **Anything touching the network / transport / crypto** | **No** |
| **Anything touching push / notifications / SOS** | **No** |

The skip path is **logged in the audit trail** (Jira's history view) so "no verification needed" doesn't quietly become the default for tickets that actually do need a device check.

## What this fixes

- Tickets like BDEV-318 → BDEV-319 (same race, marked Done twice, fixed properly the second time) become impossible: BDEV-318 would have been blocked at Verifying until a real 2-device test ran.
- The PR-merge → triage feedback loop becomes structural rather than ad-hoc — every merge produces a Verifying ticket waiting for the verifier.
- Build cuts naturally bundle Verifying tickets — the build cut is the natural verification trigger ("Build 45 is up; here are the 6 Verifying tickets it covers, please check before any are moved to Done").

## What needs to happen for this to go live

This document captures the policy. The actual Jira admin work to enable it:

1. **Create the `Verifying` status** in the BDEV project workflow. Atlassian → Project settings → Workflows → BDEV → add status between In Progress and Done.
2. **Add the `Done (no device verification)` transition** from In Progress and from Verifying. Mark it with a flag or label so the audit log can filter for it.
3. **Add a Jira automation rule:**
   - Trigger: PR merged on GitHub mentioning a BDEV ticket key (the existing GitHub ↔ Jira integration already detects this).
   - Action: transition the ticket to Verifying.
   - Comment on the ticket: "Auto-transitioned to Verifying on merge of <PR URL>. Verifier: @<assignee>."
4. **Add a validator on the Verifying → Done transition** that requires a comment containing one of: a build SHA, a commit hash, "skip" + reason, or a deployment URL. Atlassian's workflow validators support regex on comment text.

Steps 1–4 are admin-UI work in Atlassian; not API-doable in a way that's safer than the UI. Owner: **John** (Atlassian admin).

## Engineer-agent rule changes

The existing rule from `CLAUDE.md` and the per-agent boot files:

> Engineer-agents may transition Jira `To Do → In Progress`, never to Done. PM/Cowork owns Done post-merge verification.

…changes to:

> Engineer-agents may transition Jira `To Do → In Progress`, never to `Verifying` or `Done`. **`In Progress → Verifying`** is owned by the merge automation (or the assignee if automation hasn't fired yet). **`Verifying → Done`** requires a verification comment and is owned by PM/Cowork (or the verifier on a per-ticket basis).

When the Jira admin work in the previous section is done, this rule lands in `CLAUDE.md` and the boot files in a single sweep.

## Anti-patterns this guards against

- **Premature closure** — Done set on PR merge before any device test has run.
- **Orphaned regressions** — a fix that doesn't actually fix gets buried as Done; the "this is still broken" follow-up loses provenance because the original ticket is already closed.
- **Build-cut blindness** — TestFlight cuts go out without anyone explicitly running through the tickets the build covers. Verifying creates the explicit list.
- **Silent skip** — "no verification needed" gets used as a default. The audited skip path makes that visible in retrospect.

## Related

- [BDEV-318](https://heyblip.atlassian.net/browse/BDEV-318) → [BDEV-319](https://heyblip.atlassian.net/browse/BDEV-319) — same race, two tickets, the gate would have caught this.
- [BDEV-372](https://heyblip.atlassian.net/browse/BDEV-372) — the "fix exposed a latent bug" pattern this gate surfaces faster.
- [BDEV-373](https://heyblip.atlassian.net/browse/BDEV-373) — the no-op fix pattern this gate catches.
- Parent epic: [BDEV-384 Engineering Hygiene](https://heyblip.atlassian.net/browse/BDEV-384).
