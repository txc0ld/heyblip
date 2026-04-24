# APNs Operations Runbook

This runbook covers APNs secret management, key rotation, first-time setup, and
debugging for the Blip push-notifications pipeline (auth worker → relay worker
→ APNs → device). Pair this with `docs/QA_PUSH.md` for device-side validation
and `docs/ROTATION_RELAY_INTERNAL_KEY.md` for the relay internal key.

## 1. Secret inventory

All secrets live on Cloudflare Workers. Owner column indicates which worker
needs the secret.

| secret | owner | format | how to set |
|---|---|---|---|
| `APNS_KEY_ID` | auth | 10-char key id from Apple Developer | `wrangler secret put APNS_KEY_ID --name blip-auth` |
| `APNS_TEAM_ID` | auth | 10-char team id | `wrangler secret put APNS_TEAM_ID --name blip-auth` |
| `APNS_PRIVATE_KEY` | auth | base64 of .p8 (BEGIN/END lines stripped) | `base64 -w0 AuthKey_ABC.p8 \| wrangler secret put APNS_PRIVATE_KEY --name blip-auth` |
| `APNS_BUNDLE_ID_PROD` | auth | `au.heyblip.Blip` | wrangler vars (`wrangler.toml`) or `wrangler secret put` |
| `APNS_BUNDLE_ID_DEBUG` | auth | `au.heyblip.Blip.debug` | wrangler vars |
| `APNS_ENVIRONMENT` | auth | `production` (deprecated — `sandbox` bool on `device_tokens` is authoritative) | existing |
| `INTERNAL_API_KEY` | auth + relay (shared) | 32+ random bytes base64 | rotate script, see `ROTATION_RELAY_INTERNAL_KEY.md` |
| `JWT_SECRET` | auth + relay (shared) | 32+ bytes | out of scope for this PR |

## 2. Key rotation procedure

APNs auth keys rotate on suspected leak or at least yearly. The old key stays
valid until explicitly revoked in the Apple Developer portal — use that window
for zero-downtime rollover.

1. Apple Developer portal → Keys → **Generate a new APNs auth key**
2. Download the `.p8` immediately (you only get one chance — Apple will not
   let you re-download later)
3. Base64-encode the file body:
   ```bash
   base64 -w0 AuthKey_NEW.p8 > /tmp/new_key_b64
   ```
4. Push the new key + kid to the auth worker:
   ```bash
   cat /tmp/new_key_b64 | wrangler secret put APNS_PRIVATE_KEY --name blip-auth
   wrangler secret put APNS_KEY_ID --name blip-auth   # paste the new 10-char kid
   ```
5. The auth worker caches its APNs JWT for 55 minutes. The next token mint picks
   up the new key automatically. If you need an immediate roll, redeploy:
   ```bash
   cd server/auth && wrangler deploy --force
   ```
6. Validate with the curl smoke test in section 5 below. Tail logs:
   ```bash
   wrangler tail blip-auth --format pretty
   ```
   Expect `push.success` structured log entries.
7. **Only after** the new key is confirmed working in production, revoke the
   old key in the Apple Developer portal.
8. Shred the working files:
   ```bash
   shred -u /tmp/new_key_b64 AuthKey_NEW.p8
   ```

## 3. First-time setup (human follow-ups to merge this PR)

These steps require portal access and cannot be automated from CI. Assign to
John or Tay.

1. **Apple Developer Portal — Identifiers**: register App IDs
   - `au.heyblip.Blip`
   - `au.heyblip.Blip.debug`
   - `au.heyblip.Blip.notifications`
   - `au.heyblip.Blip.debug.notifications`
2. **App Group**: register `group.com.heyblip.shared` and link all four App IDs
   above. The NSE reads/writes the shared container for enrichment cache.
3. Enable **Push Notifications** capability on both Blip App IDs
   (`au.heyblip.Blip` and `au.heyblip.Blip.debug`).
4. Generate an APNs **Auth Key** (.p8) under Keys → Apple Push Notifications
   service. Note the 10-char `kid`. Record the 10-char `teamId` from the
   Membership page.
5. Set secrets per section 1:
   ```bash
   wrangler secret put APNS_KEY_ID --name blip-auth
   wrangler secret put APNS_TEAM_ID --name blip-auth
   base64 -w0 AuthKey_XXXXXXXXXX.p8 | wrangler secret put APNS_PRIVATE_KEY --name blip-auth
   ```
6. Run Neon migrations:
   ```bash
   psql "$DATABASE_URL" -f server/auth/migrations/002_push_notifications.sql
   ```
7. Deploy workers:
   ```bash
   cd server/auth  && wrangler deploy
   cd server/relay && wrangler deploy
   ```
8. Regenerate provisioning profiles in Apple Developer portal.
9. Locally: `xcodegen generate` → archive from Xcode → upload via
   `deploy-testflight.yml`.

## 4. Debugging failed pushes

Tail the auth worker while reproducing:

```bash
wrangler tail blip-auth --format pretty
```

Look for structured log lines: `push.attempted`, `push.success`, `push.failed`,
`push.suppressed`. Common failure modes:

| symptom | likely cause | fix |
|---|---|---|
| `apnsStatus=403` | JWT broken — key id / team id / kid mismatch, or `.p8` corrupted in base64 round-trip | Re-verify `APNS_KEY_ID`, `APNS_TEAM_ID`, re-encode the `.p8` |
| `apnsStatus=400 reason=BadDeviceToken` | Device reinstalled the app; token is stale | Token auto-purged from `device_tokens`; no action required |
| `apnsStatus=410` | Token expired (user uninstalled) | Token auto-purged |
| Sandbox token sent to prod host (or vice versa) | `sandbox` column wrong on `device_tokens` | Check the app's `Debug` vs `Release` build wrote the correct value at registration |
| `push.suppressed reason=channel_muted` / `friend_muted` / `quiet_hours` | Working as designed | N/A unless QA expected a push to arrive |

**Device-side debugging**: install `Console.app` on macOS, connect the iPhone,
and filter by process `apsd` (the APNs daemon) to see token registration and
push receipt events. For NSE enrichment issues, attach the Xcode debugger to
`NotificationServiceExtension` on the device and trigger a push.

## 5. Smoke test (curl)

Trigger a push end-to-end by hitting the relay's internal endpoint. This path
is what the relay uses when a peer is offline. Replace the hex values with a
real recipient token you've registered on a test device.

```bash
curl -X POST "$RELAY_INTERNAL_URL/internal/push" \
  -H "X-Internal-Key: $INTERNAL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"recipientPeerIdHex":"0011223344556677","senderPeerIdHex":"AABBCCDDEEFF0011","type":"dm","threadId":"00000000-0000-0000-0000-000000000001","badgeCount":1}'
```

Expected result: a DM tile arrives on the test device within 2 seconds, and
`wrangler tail blip-auth` logs `push.success` with the corresponding
`apnsStatus=200`.

## 6. Known limitations

- **Encrypted type opacity**: the relay cannot distinguish group vs DM vs voice
  note inside a Noise-encrypted payload. All encrypted pushes to offline peers
  are sent as `type=dm`. The NSE enriches on the device using the App-Group
  cache to recover the correct display type.
- **`APNS_ENVIRONMENT`**: retained for legacy reasons. The `sandbox` bool on
  `device_tokens` is authoritative for APNs host routing
  (`api.sandbox.push.apple.com` vs `api.push.apple.com`).
