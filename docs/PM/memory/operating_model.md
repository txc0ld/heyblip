---
name: Operating model — dispatch, merge, reviewer, PM boundaries
description: How work flows end-to-end. Dispatch channels, who merges what, Opus pinning, PM-vs-reviewer role split. Updated 2026-04-21 EOD.
type: project
originSessionId: 6e15e31b-7115-4971-bf13-07d171f32b25
---
## Dispatch

- **Trunk-based dev**, short-lived branches named `type/BDEV-XXX-short-description` (matches the Jira BDEV-N ticket key). Pre-2026-04-25 `type/HEY-XXX-...` branches in flight are still valid — the BDEV ticket carries the old HEY-N as a custom field for traceability. One Jira ticket per task.
- **John = infra/backend** (Codex or Claude Code). **Tay = frontend/UI** (Claude Code). Both non-technical — prompts must hand-hold.
- **Cowork dispatches full prompts** to `#jmac-tasks` / `#tay-tasks` as Blip bot via curl. Prompt goes directly in the Slack message as a copy-pasteable code block — never "see the Jira ticket description". See `slack_rules.md` for formatting.
- **No auto-dispatch worker exists** — every dispatch is manual on John's direction. The Jira `Assignee` field is informational only until an auto-dispatch worker is built.

## Capture rule

**Standing rule from 2026-04-21 onward: capture all bugs big or small.** When reviewing PRs, working in code, or chasing Sentry noise, every finding gets a Jira BDEV ticket filed in the same pass — no mental notes, no "I'll remember this later". See `feedback_file_review_findings.md`.

**Standing rule from 2026-04-26 onward: every new BDEV ticket gets a `parent` Epic** from the 9-Epic catalog (`reference_epic_catalog.md`). No orphans. If a ticket genuinely doesn't fit any Epic, ping John before filing rather than parking it under a misfit Epic by default.

## Merge pipeline

- **John merges all PRs** via GitHub PAT. PM and engineer-agents stop at branch pushed + PR opened + `#blip-dev` notification — John clicks merge.
- **PM has the PAT available** for merging only when John gives explicit per-instance authorization ("merge it", "merge everything", etc.). Match the scope precisely; don't extrapolate.
- **Never merge on yellow CI** — wait for green, even when authorized.
- **Post-merge (PM duty regardless of who merged)**: verify the change landed on `main` (read code, don't trust commit msg). Transition the Jira ticket to Done with a comment linking PR + commit hash.
- **PAT self-approval limitation**: GitHub PAT (iamjohnnymac) cannot approve PRs where the PAT owner pushed the last commit. Workaround on authorized merges: merge directly without formal approval.

### Reviewer pre-flight — added 2026-04-21

Before reviewing a PR, reviewer MUST `git fetch origin && git checkout main && git pull` so the local base matches origin. Stale-local-main bit us twice today on PRs #250 and #252 — see `tooling_gotchas.md`. Tracked by **HEY1312**.

## Model pinning

- **Opus 4.7 pinned** for all reviewer/merger tasks. Don't downgrade — the reasoning quality on diffs is materially better and we've seen clean catches it wouldn't make on Sonnet.
- PM sessions default to whatever the session was spawned on; no explicit pin.

## Ticket status — who owns transitions

- **`To Do → In Progress`** can be moved by **either** the engineer-agent (when starting work) **or** PM/Cowork (when dispatching). Whichever happens first; idempotent if both try.
- **`In Progress → Done` is PM/Cowork-only.** This transition follows post-merge verification — PM reads `main` to confirm the change actually landed (see `feedback_verification_rules.md`), comments with PR + commit hash, then transitions. Engineer-agents must NOT self-transition to Done. Resolution auto-sets to Done on close.
- **Engineer-agent allowed Jira writes:** `Assignee` → self when claiming, `To Do → In Progress` transition, comments (especially PR URL), paste PR URL into description.
- PM never posts as John in chat, never reveals bot orchestration.

(Updated 2026-04-26: previous version of this file said "engineer-agents NEVER transition" — that's been relaxed to allow the To Do → In Progress half. The Done transition stays PM-only because of the post-merge verification step.)

## Escalation to John

Only ping John for:
- Merge conflicts the reviewer can't resolve without direction.
- Worker deploys (`wrangler deploy` commands go to `#jmac-tasks`).
- CI failures the reviewer can't diagnose.
- Sentry dashboard clicks (no API for "Resolved in next release").
- Conflicts or policy decisions — e.g., scope creep, dependency adds.
