# App Store Screenshot Capture Spec

**Audience:** John (manual capture in simulator)
**Ticket:** [BDEV-364](https://heyblip.atlassian.net/browse/BDEV-364)
**Last reviewed:** 2026-04-27

This is the spec for capturing the App Store screenshots required at the two largest sizes Apple currently mandates. Apple auto-scales these for smaller devices, so getting the largest size right covers the listing.

## Apple's current requirements

| Device class | Resolution (portrait) | Min — max count | Format |
|---|---|---|---|
| **iPhone 6.9"** (iPhone 16 Pro Max / 17 Pro Max) | 1290 × 2796 px | 3–10 | PNG or JPEG, no alpha, sRGB |
| **iPad 13"** (iPad Pro M-series 13") | 2064 × 2752 px | 3–10 | PNG or JPEG, no alpha, sRGB |

Status bar must show: **full battery, full signal (5 bars), no carrier name, sensible time (Apple's editorial guidance is `9:41`)**. This is non-negotiable — Apple rejects screenshots with low-battery or "Searching…" status bars.

## What you'll need before you start

1. **A Release build of the app** (BDEV-362 verified — debug overlay is gated off in release).
2. **The reviewer demo account credentials** ([BDEV-366](https://heyblip.atlassian.net/browse/BDEV-366)) provisioned via wrangler secrets, OR a real test account you've signed in with.
3. **Two simulators booted:**
   - **iPhone 17 Pro Max** simulator (or iPhone 16 Pro Max if 17 isn't available) — gives the 6.9" screenshots
   - **iPad Pro 13"** simulator
4. **Status bar override** applied to both simulators via `xcrun simctl status_bar` (commands below).
5. **A clean home indicator** — no Reachability, no notifications.

## Set the status bar to Apple's editorial preset

Run this once per simulator after boot, before capturing anything:

```bash
# iPhone 6.9"
xcrun simctl status_bar "iPhone 17 Pro Max" override \
  --time "9:41" \
  --dataNetwork wifi \
  --wifiMode active \
  --wifiBars 3 \
  --cellularMode active \
  --cellularBars 4 \
  --batteryState charged \
  --batteryLevel 100

# iPad 13"
xcrun simctl status_bar "iPad Pro 13-inch (M4)" override \
  --time "9:41" \
  --dataNetwork wifi \
  --wifiMode active \
  --wifiBars 3 \
  --cellularMode active \
  --cellularBars 4 \
  --batteryState charged \
  --batteryLevel 100
```

(Adjust simulator name to whatever's in `xcrun simctl list devices` for your Xcode version.)

Verify with `xcrun simctl status_bar "iPhone 17 Pro Max" list` — you should see your overrides applied.

## Capture command

For each shot:

```bash
xcrun simctl io booted screenshot --type png /path/to/output/01-mesh-discovery.png
```

If you have multiple simulators booted, replace `booted` with the simulator UUID from `xcrun simctl list`.

## The shots — script in order

The headline value props the App Store listing should communicate. Capture all six in the SAME aspect ratio and lighting (dark mode preferred — Blip's primary aesthetic) so they look like a coherent set on the listing.

### Shot 1 — Mesh discovery

**Hook:** "See who's around — even with no signal."

**Screen:** Nearby tab. Friend / peer list with 3–5 entries showing avatar circles, usernames, RSSI signal bars. At least one entry should be marked as a friend (verified badge or "Friends" tag) and at least one as a stranger (Add Friend button visible).

**State to seed:** Use the demo account or the simulator with a few peers visible from a real BLE radio or seeded peers. If pure simulator (no BLE), use SwiftUI Preview-equivalent state — the list appearance is what matters.

**Filename:** `01-mesh-discovery.png` (per device size suffix below)

### Shot 2 — Encrypted DM

**Hook:** "End-to-end encrypted. Always."

**Screen:** A chat thread mid-conversation. Sender name visible at top with verified badge. 4–6 message bubbles (mix of inbound + outbound, text-only — image/voice notes are separate shots). Padlock or "encrypted" indicator visible somewhere.

**Sample message content:** keep it festival-flavoured and demo-safe:
- "where you at? meet by the pyramid stage?"
- "yeh just at the food trucks. give me 5"
- "ok cool"
- "what was that band called from earlier??"

No real names, no PII, no anything that looks like a real conversation about a real person.

**Filename:** `02-encrypted-dm.png`

### Shot 3 — Festival / event view

**Hook:** "Find your crew at every festival."

**Screen:** Events tab. Show 2–3 event cards with images / logos (use placeholder festival imagery — no real festivals unless you have rights). Active event at the top has an artist schedule preview ("Up next" or similar).

**Filename:** `03-events-tab.png`

### Shot 4 — SOS flow

**Hook:** "Trouble at an event? One tap to your crew."

**Screen:** SOS confirmation sheet mid-press (the 2-second hold confirmation). Show the pulsing button + "SOS active in 2s" countdown UI.

**State to seed:** Trigger SOS via long-press, screenshot during the countdown phase. Don't actually fire the SOS — cancel before the countdown completes.

**Filename:** `04-sos-flow.png`

### Shot 5 — Friend-add flow (QR / username)

**Hook:** "Add friends instantly. No phone numbers."

**Screen:** Add Friend sheet. Show the QR code prominently in the centre + "Or add by username: @yourhandle" below. Camera viewfinder for QR scan can be in a smaller secondary panel if the layout supports it.

**Filename:** `05-friend-add.png`

### Shot 6 — Onboarding (welcome step)

**Hook:** "Three steps. Then you're on the mesh."

**Screen:** Onboarding step 1 (WelcomeStep) — the "Chat at events, even without signal" hero illustration with the radiating mesh nodes.

**Filename:** `06-onboarding.png`

## Per-device output

Capture each of the 6 shots on each of the two device classes. Output filenames:

```
screenshots/
  iphone-6.9/
    01-mesh-discovery.png         (1290 × 2796)
    02-encrypted-dm.png
    03-events-tab.png
    04-sos-flow.png
    05-friend-add.png
    06-onboarding.png
  ipad-13/
    01-mesh-discovery.png         (2064 × 2752)
    02-encrypted-dm.png
    ...
```

12 final PNGs (6 shots × 2 device sizes).

## Pre-flight checklist before each capture

Run through this every time you screenshot — mistakes are easy and Apple is strict:

- [ ] Status bar shows 9:41, full bars, full battery (verify via `xcrun simctl status_bar list`)
- [ ] No notification banner currently visible
- [ ] Home indicator is at the bottom (don't crop it out — Apple rejects)
- [ ] No debug overlay visible (BDEV-362 — verify the triple-tap gesture is gated; should be in a Release build)
- [ ] No PII visible anywhere — sample data only
- [ ] No spinners / loading states — wait for content to fully load
- [ ] Dark mode (preferred for Blip's aesthetic)
- [ ] No keyboard up unless that's the intentional shot

## Optional marketing overlays

Apple allows marketing overlay text on screenshots **as long as it's an honest representation of in-app UX**. If you want to add headline copy ("End-to-end encrypted. Always.") as overlay text, do it in a separate compositing step with a tool like Figma or Photoshop. Keep the underlying screenshot uncropped + unmodified beneath the overlay so a reviewer can verify the UI matches the marketing claim.

If you skip marketing overlays for v1, the raw screenshots are still valid — App Store listings without overlays are common and Apple has no preference.

## Upload to App Store Connect

App Store Connect → My Apps → HeyBlip → App Store → Media → Screenshots:

1. Select **iPhone 6.9" Display** in the device picker.
2. Drag all 6 PNGs from `screenshots/iphone-6.9/` into the upload area, in order.
3. Switch to **iPad Pro 13" Display**, drag the iPad set.
4. Save.

Apple auto-scales these for smaller iPhone / iPad sizes, so you don't need to capture the 6.5", 5.5", or older iPad sizes manually unless you specifically want a different shot per device class.

## Common rejection reasons (avoid these)

- **Status bar shows real signal/battery values** — looks unprofessional, gets rejected.
- **PII or real-looking personal data visible in the chat thread** — privacy concern.
- **Sample data that suggests illegal activity** — even jokingly. Stick to festival-flavoured content.
- **Different aspect ratios across the set** — looks inconsistent on the listing.
- **Wrong resolution** — even off by a few pixels gets rejected.
- **Marketing claims that don't match the actual UI** — don't show "100% encryption" in overlay text if the UI doesn't say that.

## Related

- [BDEV-362](https://heyblip.atlassian.net/browse/BDEV-362) — debug overlay must be gated off in Release (verified in PR #290).
- [BDEV-366](https://heyblip.atlassian.net/browse/BDEV-366) — reviewer demo account, useful for capturing chat-state shots.
- [BDEV-365](https://heyblip.atlassian.net/browse/BDEV-365) — App Privacy declaration submitted alongside screenshots.
- [BDEV-359](https://heyblip.atlassian.net/browse/BDEV-359) — Info.plist purpose strings (related App Store hygiene).

## When this changes

Re-capture screenshots whenever:

- The app's primary UX visibly changes (new tabs, redesigned chat bubbles, etc.).
- A major iOS version changes the system chrome (status bar, home indicator).
- Apple introduces a new device class that becomes the new "largest size" required.
- We add a new headline feature worth a screenshot of its own.
