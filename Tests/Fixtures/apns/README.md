# APNs simulator fixtures

Each `.apns` file is a drag-drop fixture for the iOS Simulator, matching the
`blip` envelope the production worker sends. Use these to iterate on
NotificationService Extension enrichment, category actions, and deeplink
routing without needing the Cloudflare Workers chain.

## Drag-drop
1. Boot the Simulator with the Debug Blip build (bundle ID `au.heyblip.Blip.debug`)
2. Drag the `.apns` file onto the Simulator window
3. The push lands immediately; NSE runs in-process and your breakpoints hit

## CLI
```
xcrun simctl push booted au.heyblip.Blip.debug Tests/Fixtures/apns/dm.apns
```

## Fixture inventory

| fixture | type | interruption | notes |
|---|---|---|---|
| `friend_request.apns` | `friend_request` | passive | Accept/Decline actions on tile |
| `friend_accept.apns` | `friend_accept` | passive | Opens Profile > Friends |
| `dm.apns` | `dm` | active | Tap opens ChatView |
| `group_message.apns` | `group_message` | active | `thread-id` groups by channel |
| `group_mention.apns` | `group_mention` | time-sensitive | Breaks through non-critical Focus |
| `voice_note.apns` | `voice_note` | active | Icon/body reflect voice note |
| `sos.apns` | `sos` | critical | Bypasses every suppression path |
| `silent_badge_sync.apns` | `silent_badge_sync` | (none) | `content-available: 1`, badge clears |

## Regenerating
These match the `buildPayload` factory in `server/auth/src/apns/payloads.ts`.
If you change the envelope shape, regenerate all fixtures.
