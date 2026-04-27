# Verifying-Gate Jira Setup — Step-by-Step

**Audience:** John (Atlassian admin)
**Ticket:** [BDEV-378](https://heyblip.atlassian.net/browse/BDEV-378)
**Last reviewed:** 2026-04-27
**Estimated time:** 15–20 minutes
**Companion doc:** `docs/PROCESS-VERIFICATION-GATE.md` (the policy this enables)

This is the click-by-click recipe for enabling the **Verifying** status in the BDEV Jira workflow. The policy is already documented in `PROCESS-VERIFICATION-GATE.md` (PR #293). This doc is the execution guide — read once, do once, then archive.

## Why we're doing this in the UI not via API

BDEV is a production Jira project with 60+ live tickets and ~50 daily transitions. Workflow modification via the REST API is technically possible but high-risk: a mistake in the workflow XML can leave tickets stuck in invalid states or block all transitions until you re-edit. The Atlassian admin UI has guardrails (preview, validate, soft-publish) that the API doesn't expose.

**Recommendation: do this in the UI, end of story.** The five steps below take ~15 min and have built-in undo at each stage.

## Prerequisites

- You're logged into Atlassian as the admin (the `macca.mck@gmail.com` account).
- BDEV is the project you want to modify (verify at https://heyblip.atlassian.net/jira/software/projects/BDEV/settings).
- No active work depends on the workflow finalising in the next 30 minutes (changes are non-disruptive but staff might briefly see odd transitions during the soft-publish phase).

## Step 1 — Add the `Verifying` status

1. Atlassian top-right menu → **Settings → Issues → Statuses**.
2. Click **Add status**.
3. Fill in:
   - **Name:** `Verifying`
   - **Category:** `In Progress` (yellow — same as the existing "In Progress" status; this is correct because the work is still in flight, just in a different phase)
   - **Description:** `Awaiting on-device verification or smoke test before transitioning to Done. Set automatically by the GitHub merge automation rule; cleared by a verification comment.`
4. Click **Create**.

You now have a global status named `Verifying`. It's not yet attached to any workflow.

## Step 2 — Add `Verifying` to the BDEV workflow

1. Atlassian top-right → **Settings → Issues → Workflows**.
2. Find the workflow used by the BDEV project. It's named something like **BDEV: Software Simplified Workflow** or **BDEV: Scrum Workflow**. If unsure, go to your project (`/projects/BDEV`) → **Project settings → Workflows** and click the workflow name to identify it.
3. Click the workflow → **Edit**. The diagram view opens.
4. **Add the new status node:**
   - Click **Add status** in the toolbar.
   - Pick `Verifying` from the dropdown (the status you created in Step 1).
   - Drop it on the canvas between **In Progress** and **Done**.
5. **Add transitions:**
   - From **In Progress** → drag a transition arrow to **Verifying**. Name the transition `Mark verifying`. Save.
   - From **Verifying** → drag a transition arrow to **Done**. Name the transition `Mark verified`.
   - From **Verifying** → drag a transition arrow back to **In Progress** (in case verification fails and engineering needs more work). Name `Reopen for fix`.
6. **Add the "Done (no device verification)" skip path:**
   - From **In Progress** → drag a transition arrow to **Done**. Name `Done (no device verification)`.
   - This transition exists alongside the In-Progress → Verifying path; users pick which one applies.
7. Click **Publish workflow** (the diagram view's button). Atlassian asks if you want to migrate existing tickets — pick **"Don't migrate"** (existing In-Progress tickets stay In Progress; they only enter Verifying via the new automation rule below).
8. Confirm.

The workflow now has Verifying. Existing tickets are unaffected.

## Step 3 — Add a comment validator on `Verifying → Done`

This is the bit that enforces the verification-comment requirement.

1. Back in the workflow editor → click the **`Mark verified`** transition (the arrow from Verifying to Done).
2. **Validators tab → Add validator → Regular Expression Check**.
3. Configure:
   - **Field to validate:** `Comment`
   - **Regular expression:** `(?i)(build [a-f0-9]{6,}|\b[a-f0-9]{7,40}\b|skip:|build \d+|deployed|smoke[ -]?trace)`
   - **Error message:** `Verifying → Done requires a comment with one of: a commit hash (e.g. 7d169e2), a build SHA, "skip: <reason>", a deployment URL, or "smoke trace passed".`
4. Save the validator.
5. Click **Publish workflow** again.

This validator fires when someone tries to transition Verifying → Done. It checks that the **most recent comment on the issue** matches the regex. If not, the transition fails with the error message above.

**Tradeoff to be aware of:** the regex is permissive on purpose. It doesn't strictly enforce a particular format — it just blocks transitions where there's no plausible verification artifact in the comment. A determined human can paste anything matching `\b[a-f0-9]{7,40}\b` and pass. This is intentional — strict format enforcement creates friction that engineers route around. The audit trail is the real check (Step 5).

## Step 4 — GitHub → Jira automation rule

This is the rule that auto-transitions `In Progress → Verifying` when a PR mentioning a BDEV ticket is merged.

1. Atlassian top-right → **Settings → Apps → Automation** (or **Project settings → Automation** if you prefer per-project rules).
2. Click **Create rule**.
3. Trigger: **Branch merged** (this is the GitHub trigger, comes from the existing GitHub-Jira integration).
4. Filter / Conditions:
   - **PR title or branch name contains BDEV-** (regex: `BDEV-\d+`)
   - **Issue status is `In Progress`** (so we don't accidentally transition tickets that are already in another status)
5. Action: **Transition issue → Mark verifying** (the transition you named in Step 2).
6. Action: **Add comment** with body:
   ```
   Auto-transitioned to Verifying on merge of {{pullRequest.url}}.
   Verification comment required for transition to Done — include a commit SHA, build number, smoke-trace note, or "skip: <reason>".
   Verifier: {{issue.assignee.displayName}}
   ```
7. Save the rule. Enable it.

Test: when a PR with `BDEV-N` in the title or branch name is merged, the matching ticket should auto-transition to Verifying and post the comment. **Test with a low-risk ticket first** (e.g. a docs-only ticket that's already In Progress) before unleashing on critical work.

## Step 5 — Audit-log filter for the skip path

To make "Done (no device verification)" transitions visible in retrospect:

1. **Settings → Issues → Workflows** → BDEV workflow → click the **`Done (no device verification)`** transition.
2. **Post-functions tab → Add post-function → Update Issue Field**.
3. Set:
   - **Field:** `Labels`
   - **Value:** `done-no-device-verification`
4. Save and publish.

Now any ticket transitioned via the skip path automatically gets a `done-no-device-verification` label. You can run a JQL query at any time:

```jql
labels = "done-no-device-verification" ORDER BY resolutiondate DESC
```

If you see this label on tickets that should have had device verification (anything in BDEV-380 push, BDEV-383 chat, BDEV-385 transport), that's the signal that the skip path is being abused. Triage and re-open as needed.

## Step 6 — Land the engineer-agent rule update

Once Steps 1–5 are live and you've smoke-tested with one PR merge:

1. Open `~/heyblip/CLAUDE.md`.
2. Search for: `Engineer-agents may transition Jira To Do → In Progress, never to Done.`
3. Replace with:
   ```
   Engineer-agents may transition Jira `To Do → In Progress`, never to `Verifying` or `Done`. `In Progress → Verifying` is owned by the GitHub merge automation rule. `Verifying → Done` requires a verification comment (commit SHA, build SHA, smoke-trace note, or `skip: <reason>`) and is owned by PM/Cowork or the verifier on a per-ticket basis. The `Done (no device verification)` skip path is for CI / docs / refactor / observability changes only — anything user-facing, transport, crypto, or push must go through Verifying.
   ```
4. Update the matching paragraph in your boot-file memory (`~/.claude/projects/.../memory/MEMORY.md` and the relevant feedback files) so future agent sessions inherit the new rule.
5. Commit on a small follow-up PR titled `chore(claude): update agent rule for Verifying gate (BDEV-378 follow-up)`.

## Rollback plan

If anything goes wrong during the workflow change, Atlassian's workflow editor has a **Discard draft** button before publish — that's your "undo". After publish, the rollback is:

1. Re-edit the workflow.
2. Delete the `Verifying` status node and its transitions.
3. Republish.

Tickets currently in Verifying would need to be manually transitioned back to In Progress before deletion (Atlassian flags this).

The automation rule (Step 4) can be disabled with a single toggle without touching the workflow itself.

## Smoke test plan

After Steps 1–5 are live, validate with one real PR:

1. Pick a docs-only ticket that's currently In Progress (e.g. one of the open PRs from today's batch — PR #293 → BDEV-353 or BDEV-378 itself once it merges).
2. Confirm the merge auto-transitions to Verifying.
3. Confirm the auto-comment appears.
4. Try transitioning the ticket to Done **without** a verification comment — confirm the validator blocks with the error message.
5. Add a comment containing the commit SHA — try Verifying → Done again, confirm it succeeds.
6. Try transitioning a different In-Progress ticket via "Done (no device verification)" — confirm it auto-applies the skip-path label.

If all 6 work, you're done. Update `CLAUDE.md` per Step 6.

## When to revisit this doc

- A new Jira workflow is introduced for a different project that needs the same gate.
- Atlassian changes the admin UI such that the click-paths above don't match.
- The "skip path is being abused" signal fires (Step 5 audit) and you want to tighten the validator regex.

Otherwise, archive this doc once the gate is live for ~30 days without incident.
