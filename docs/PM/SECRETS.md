# PM Secrets

The PM session needs these secrets. They are NOT in this repo — they live in a gitignored env file on John's machine.

## Where the file is

```
~/heyblip/.claude/skills/secrets/.env
```

This path is gitignored via `.claude/` (already in `.gitignore`). The file should never be committed.

## What's in it

```bash
# Atlassian API token for heyblip.atlassian.net (Jira BDEV + Confluence BLIP).
# Authenticated as macca.mck@gmail.com (John). Use Basic auth header: base64(email:token).
# Rotates: per-incident or quarterly. Last rotation: 2026-04-25.
# Get from: https://id.atlassian.com/manage-profile/security/api-tokens
# Create CLASSIC token (the plain "Create API token" button, NOT "Create API token with scopes").
# Scoped tokens default to read-only and break write operations.
export ATLASSIAN_TOKEN="ATATT3xFf..."
export ATLASSIAN_EMAIL="macca.mck@gmail.com"

# Slack bot token for the "Blip" bot (App ID A0APDURFTMH, Bot User U0APGUH16SZ).
# Scopes: chat:write, channels:read, channels:history, files:read, users:read, etc.
# Rotates: only on incident. Get from: https://api.slack.com/apps/A0APDURFTMH/oauth
export SLACK_BOT_TOKEN="xoxb-10798501476390-..."

# GitHub PAT for iamjohnnymac. Scopes: repo, workflow.
# Rotates: per GitHub policy. Used by gh CLI and by curl against api.github.com.
# IMPORTANT: NOT embedded in any git config — keep it env-only. Older clones may have
# https://ghp_<token>@github.com/... in .git/config — if you find any, rotate the token
# immediately and run: git remote set-url origin https://github.com/txc0ld/heyblip.git
export GITHUB_PAT="ghp_..."

# === Legacy (read-only archive access only) ===

# Notion personal integration token. The HeyBlip Notion workspace was the issue tracker
# from 2026-04-24 to 2026-04-25. Now an archive. Keep the token only if you need to
# read historical pages or the original Tasks DB.
export NOTION_TOKEN="ntn_..."

# Bugasura API key. Issue tracker 2026-04-13 to 2026-04-24. Archive. Each Jira ticket
# has a Bugasura URL custom field for direct lookup; the API key is rarely needed now.
export BUGASURA_API_KEY="ef611198..."
```

## How to verify each one works

```bash
source ~/heyblip/.claude/skills/secrets/.env

# Atlassian — should print {"emailAddress":"macca.mck@gmail.com","accountId":"...","displayName":"John McKean",...}
curl -s -u "$ATLASSIAN_EMAIL:$ATLASSIAN_TOKEN" -H "Accept: application/json" \
  "https://heyblip.atlassian.net/rest/api/3/myself" | jq '{emailAddress, displayName}'

# Jira — list 1 issue from BDEV
curl -s -u "$ATLASSIAN_EMAIL:$ATLASSIAN_TOKEN" -H "Accept: application/json" \
  "https://heyblip.atlassian.net/rest/api/3/search/jql?jql=project%3DBDEV&maxResults=1" \
  | jq '.issues[0].key'

# Confluence — fetch the home page
curl -s -u "$ATLASSIAN_EMAIL:$ATLASSIAN_TOKEN" -H "Accept: application/json" \
  "https://heyblip.atlassian.net/wiki/api/v2/pages/458861" | jq '{title, version: .version.number}'

# Slack bot — should print {"ok":true,"team":"The Mesh","user":"Blip",...}
curl -s -H "Authorization: Bearer $SLACK_BOT_TOKEN" "https://slack.com/api/auth.test" | jq .

# GitHub PAT — list open PRs
gh pr list --repo txc0ld/heyblip --state open

# === Legacy verification (archive access) ===

# Notion — should print "Claude.ai HeyBlip"
curl -s -H "Authorization: Bearer $NOTION_TOKEN" -H "Notion-Version: 2022-06-28" \
  "https://api.notion.com/v1/users/me" | jq .name

# Bugasura — list any imported HEY-N
curl -s -G -H "Authorization: Basic $BUGASURA_API_KEY" \
  --data-urlencode "team_id=101842" --data-urlencode "project_id=135167" \
  --data-urlencode "sprint_id=152746" --data-urlencode "max_results=5" \
  "https://api.bugasura.io/v1/issues/list" | jq '.issue_list[0].issue_id'
```

If any of the live tokens fail, the secret is stale or wrong — surface to John, do NOT scrape from disk.

## Rotation

If a token is compromised or rotated:
1. John updates the env file directly.
2. Cowork (you) does NOT need to be re-prompted — next `source` picks up the new value.

**Atlassian token specifically:** if rotating, regenerate as a CLASSIC token at https://id.atlassian.com/manage-profile/security/api-tokens. Scoped tokens (the "with scopes" flow) default to read-only and will break write operations like ticket creation, transitions, and Confluence page updates.

## What's NOT in this file

- Apple Developer / App Store Connect credentials — those are John's only, in his macOS Keychain + GitHub Actions Secrets. PM doesn't touch the TestFlight pipeline directly.
- Cloudflare Workers (`wrangler` auth) — John's terminal only.
- Sentry API tokens — not currently provisioned for PM. Sentry dashboard cleanup is a manual John-clicks task.
- Apple Developer / ASC API key — same as above, John's only.

## File creation template

If `~/heyblip/.claude/skills/secrets/.env` doesn't exist yet, copy `docs/PM/SECRETS.example` to that path and have John populate the actual values. The example file has the variable names but no values.
