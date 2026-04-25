# Push Notifications — QA Runbook (HEY-1321)

Physical-device QA for the Blip push-notifications pipeline. Work the full
matrix before signing off a TestFlight build. Pair with `docs/OPS_APNS.md` for
secret / rotation details.

## 1. Device matrix

| device | network | configs to test |
|---|---|---|
| iPhone 15 | LTE | foreground / background / terminated, Focus on/off, airplane-mode recovery |
| iPhone 17 Pro | WiFi-only | foreground / background / terminated, Focus on/off, airplane-mode recovery |
| 2-device (same user) | any | badge convergence on receive / read / mute |

For every row, record:
- build number (TestFlight or local archive)
- iOS version
- APNs environment (sandbox / production) derived from `device_tokens.sandbox`
- screenshot of a successful tile (attach to the HEY-1321 ticket)

## 2. Per-type checklist

### friend_request
- [ ] Tile title = "Friend request", body = sender display name ("alex wants to connect")
- [ ] Tap opens **Profile → Friends** scoped to the sender
- [ ] **Accept** category action completes the handshake without opening the app
- [ ] **Decline** category action dismisses and marks the Friend as declined

### friend_accept
- [ ] Tile title = "Friend request accepted", body references accepter
- [ ] Tap opens **Profile → Friends** at the accepter's row
- [ ] Badge reflects pending unread friend activity

### dm
- [ ] Tile title = sender display name, body = "Sent you a message"
- [ ] `thread-id` groups multiple bubbles from the same sender into one stack
- [ ] Tap opens **ChatView** at the correct channel
- [ ] **Reply** (text input) posts without opening the app
- [ ] **Mark Read** clears the badge for that thread

### group_message
- [ ] Tile title = channel name ("Afterhours crew"), body = "alex sent a message"
- [ ] `thread-id` groups by channel (not by sender)
- [ ] Tap opens ChatView at the correct channel

### group_mention
- [ ] Tile title = channel name, body = "alex mentioned you"
- [ ] `interruption-level` = `time-sensitive` — breaks through non-critical Focus
- [ ] Tap opens ChatView and scrolls to the mention

### voice_note
- [ ] Tile body = "Sent a voice note" with voice-note icon
- [ ] Tap opens ChatView; voice bubble plays immediately on open

### sos
- [ ] Tile breaks through **every** suppression path: Focus, DND, quiet hours,
      muted friend, muted channel, type opt-out
- [ ] Critical sound (`sos_critical.caf`) plays at system critical volume
- [ ] No dismissive category action (user cannot swipe-dismiss without viewing)
- [ ] **View** action opens the SOS alert screen

### silent_badge_sync
- [ ] No banner appears
- [ ] Badge updates to the server-authoritative value
- [ ] Disconnect the device for >5 min, then reconnect → silent sync fires and
      badge converges on both devices of the same user

## 3. Suppression tests

Run each of these on a 2-device setup (sender → receiver, same user for badge
test, different users for friend/channel mute tests). Tail the worker during
each test:

```bash
wrangler tail blip-auth --format pretty
```

- [ ] **Channel mute**: mute the thread in Profile → send a DM from the other
      device → push does **not** arrive. Logs show
      `push.suppressed reason=channel_muted`.
- [ ] **Friend mute**: mute the friend → send a DM → push does not arrive.
      Logs show `reason=friend_muted`.
- [ ] **Quiet hours**: set quiet hours covering now → send a DM → push
      suppressed. Logs show `reason=quiet_hours`.
- [ ] **SOS bypass**: with all three suppressions above active, send an SOS →
      push **does** arrive as critical.

## 4. Multi-device badge convergence

Sign in the same user on two devices (or 1 device + simulator).

- [ ] From a 3rd-device sender, send 3 DMs → both receivers show badge `3` on
      the lock screen
- [ ] Open the thread on **Device A** → Device A badge goes to `0` immediately
- [ ] **Device B** badge goes to `0` within 5 s (silent-push fan-out)
- [ ] Mute a different thread on Device A → Device B reflects the mute within
      one send cycle

## 5. Drag-drop fixture guide

`.apns` files in `Tests/Fixtures/apns/` can be dragged onto a running
Simulator window or pushed via the CLI:

```bash
xcrun simctl push booted au.heyblip.Blip.debug Tests/Fixtures/apns/dm.apns
```

Useful for iterating on NSE enrichment and category-action wiring without
needing the worker chain. See `Tests/Fixtures/apns/README.md` for the fixture
inventory.

Typical dev loop:
1. Attach Xcode to the `NotificationServiceExtension` scheme
2. Drag `Tests/Fixtures/apns/dm.apns` onto the simulator window
3. Breakpoint hits in `NotificationService.didReceive(_:withContentHandler:)`
4. Inspect enrichment, tweak, rebuild

## 6. TestFlight release gate

Every box below must be checked before uploading a build to TestFlight.

- [ ] All device-matrix boxes green, screenshots attached to the HEY-1321 ticket
- [ ] `wrangler tail` shows no 410 / 403 storms during a 30-min soak
- [ ] `npm test` in `server/auth` and `server/relay` green in CI
- [ ] Manual QA sign-off from John or Tay (names in HEY-1321 comments)
- [ ] Secrets set on Cloudflare: `APNS_KEY_ID`, `APNS_TEAM_ID`,
      `APNS_PRIVATE_KEY`, `APNS_BUNDLE_ID_PROD`, `APNS_BUNDLE_ID_DEBUG`
- [ ] Neon migration `002_push_notifications.sql` applied
- [ ] `xcodegen generate` produces a clean diff
- [ ] `beta-push-v1` archive uploaded via `deploy-testflight.yml`
- [ ] HEY-1321 ticket updated with release notes
