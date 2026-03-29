<h1 align="center">Blip — Work Plan</h1>

<p align="center">
  <strong>Tay</strong> (Frontend, UX/UI, Design + Backend) &nbsp;&bull;&nbsp; <strong>John</strong> (Backend, Data, SEO, Infrastructure)
</p>

---

## How This Works

Every task is tagged with an owner. Some tasks are collaborative — both names appear. Priority is **P0** (must have for v1) through **P2** (nice to have). Work in priority order within your lane.

**Note:** Tay handles frontend/design AND shares backend work. Tasks are balanced evenly across both people.

---

## Tay — Frontend, UX/UI, Visual Polish + Shared Backend

> Your lane: Everything the user sees and touches, plus core backend systems. Make it beautiful AND make key pieces work.

### P0 — Core Experience

| # | Task | Description | Status |
|---|---|---|---|
| T1 | **Onboarding flow polish** | Refine the 3-screen onboarding (SplashView, WelcomeStep, CreateProfileStep, PermissionsStep). Add real illustrations/graphics, fine-tune spring animations, test on all iPhone sizes (SE through 16 Pro Max). Ensure Plus Jakarta Sans renders perfectly at all Dynamic Type sizes. | Not started |
| T2 | **Chat UI polish** | Refine MessageBubble glass styling, test light/dark themes thoroughly, fine-tune message entrance spring physics, verify swipe-to-reply rubber-band feel, polish the morphing mic/send button transition. Make it feel as good as iMessage. | Not started |
| T3 | **Tab bar + navigation** | Polish the custom floating glass tab bar. Fine-tune the accent glow on active tab. Test matched geometry transitions between chat list and chat view. Ensure smooth cross-fade on tab switches. | Not started |
| T4 | **Avatar system** | Design avatar placeholder graphics (gradient backgrounds with initials). Polish the circular crop editor (AvatarCropView). Design the gradient ring variants (friend, nearby, subscriber). Test with real photos at all sizes. | Not started |
| T5 | **App icon + branding** | Design the Blip app icon (1024x1024). Create all required sizes for App Store. Design a simple wordmark/logo for the splash screen. Accent purple `#6600FF` as the anchor color. | Not started |
| T6 | **PaywallSheet design** | Polish the message pack purchase sheet. Make it feel inviting, not pushy. Design the pack option cards, "best value" badge, and the soft prompt that appears after free messages are used. | Not started |
| T7 | **Typing indicator + status badges** | Fine-tune the 3-dot typing indicator pulse timing. Polish delivery status checkmark animations (sent/delivered/read). Ensure they feel subtle, not distracting. | Not started |

### P0 — Festival & Map Experience

| # | Task | Description | Status |
|---|---|---|---|
| T8 | **Stage map design** | Design the interactive stage map experience. How do stage hotspots look? How does the crowd pulse heatmap overlay feel? Design meeting point pin visuals. Test with real festival map images. | Not started |
| T9 | **Schedule view** | Polish ScheduleView and SetTimeCell. Design the "LIVE NOW" badge. Make the save star and reminder bell feel satisfying to tap. Ensure the collapsible stage sections are intuitive. | Not started |
| T10 | **Nearby tab particles** | Refine MeshParticleView — the ambient floating dots representing mesh peers. Tune particle count, float speed, bloom pulse on new peer. Make it feel alive but not distracting. | Not started |

### P0 — Medical/SOS

| # | Task | Description | Status |
|---|---|---|---|
| T11 | **SOS confirmation design** | Polish the 3-tier SOS confirmation (tap/slide/hold). Design the countdown circle animation for Red severity. Ensure the 10-second cancel banner is unmissable. The hold-for-3s haptic escalation must feel urgent but not panic-inducing. | Not started |
| T12 | **SOS button design** | Refine the persistent floating SOS pill. It must be visible but not intrusive in normal use. Red accent on press must feel immediate. 60pt tap target. | Not started |

### P1 — Visual Polish

| # | Task | Description | Status |
|---|---|---|---|
| T13 | **Waveform visualizer** | Polish WaveformView for voice notes and PTT. Tune the bezier curve smoothness, gradient fill, and the mirrored bottom wave. Make recording feel expressive. | Not started |
| T14 | **Ripple effect for PTT** | Tune the expanding concentric rings animation. Color, speed, ring count, ring spacing. It should feel like sonar/radio waves. | Not started |
| T15 | **Connection banner** | Polish the "Connected to X people nearby" glass capsule. Entry/exit animations. Auto-dismiss timing (3s). It should feel informative, not interruptive. | Not started |
| T16 | **Empty states** | Design empty state graphics for: no chats, no friends, no nearby peers, no festival joined. Each should be on-brand with helpful text. | Not started |
| T17 | **Dark/light theme QA** | Test every screen in both themes. Verify glass materials, borders, text contrast, and accent purple work perfectly in both. Fix any inconsistencies. | Not started |
| T18 | **Responsive layout QA** | Test all views on iPhone SE, iPhone 16, iPhone 16 Pro Max, iPad (if supporting), and macOS. Fix layout breaks, text truncation, and spacing issues. | Not started |

### P0 — Backend (Tay)

| # | Task | Description | Status |
|---|---|---|---|
| T22 | **Noise XX handshake validation** | Test the full Noise XX handshake between two real devices over BLE. Verify key exchange, forward secrecy, and message encryption/decryption. Stress test with rapid connect/disconnect cycles. | Not started |
| T23 | **StoreKit 2 integration** | Configure In-App Purchase products in App Store Connect. Test purchase flow, receipt validation, transaction listener, and restore purchases. Set up server-side receipt validation endpoint. | Not started |
| T24 | **SwiftData schema validation** | Verify all 21 SwiftData models create/read/update/delete correctly. Test relationships, cascade deletes, indexes, and migration paths. | Not started |
| T25 | **SOS packet delivery guarantee** | Test SOS packets at simulated crowd scales. Verify: separate Bloom filter, TTL skip for first 3 hops, 100% relay probability, queue-jumping, dual-path. | Not started |
| T26 | **GPS precision for SOS** | Test GPS fallback chain on real devices. Verify encrypted precise location delivery to responders only. | Not started |
| T27 | **Message retry optimization** | Test MessageRetryService under poor connectivity. Verify exponential backoff, 50 max attempts, 24-hour expiry. Measure delivery success rate. | Not started |
| T28 | **CI/CD pipeline** | Set up GitHub Actions: build, test (all 3 packages + integration tests), lint. Auto-run on PR. | Not started |

### P2 — Delight

| # | Task | Description | Status |
|---|---|---|---|
| T19 | **Haptic feedback system** | Define the haptic palette: which interactions get which haptic (light/medium/heavy/selection/success/error). Implement across all interactive elements. | Not started |
| T20 | **App Store assets** | Design App Store screenshots (6.7" and 6.1"). Write App Store description. Design the preview video storyboard. | Not started |
| T21 | **Gradient background tuning** | Fine-tune the animated mesh gradient background. Adjust the purple/blue/teal drift speed, color saturation, and time-of-day shift. | Not started |

---

## John — Backend, Data, Infrastructure

> Your lane: Everything under the hood. Make it work, make it fast, make it reliable at 100K users.

### P0 — Core Infrastructure

| # | Task | Description | Status |
|---|---|---|---|
| J1 | **BLE mesh integration testing** | Test BLEService on real devices (minimum 3 iPhones). Verify dual-role central/peripheral works simultaneously. Test state restoration after app background/kill. Measure connection reliability, MTU negotiation, and throughput. | Not started |
| J2 | **Gossip routing real-world test** | Test gossip routing with 5+ devices. Verify messages hop correctly, Bloom filter dedup works, TTL decrements, and store-and-forward delivers to offline peers on reconnect. | Not started |
| J3 | **Phone verification backend** | Set up the Twilio Verify (or Firebase Auth) integration for SMS OTP. Create the minimal API endpoint. Test the full send/verify/store flow. Ensure rate limiting (60s cooldown, 5/hour). | Not started |
| J4 | **WebSocket relay server** | Build and deploy the `wss://relay.blip.app/ws` relay. Zero-knowledge: receives binary packets, forwards by recipient ID, stores nothing. Cloudflare Workers with Durable Objects. | Not started |

### P0 — Festival Infrastructure

| # | Task | Description | Status |
|---|---|---|---|
| J8 | **Festival manifest system** | Set up the CDN-hosted JSON manifest. Build the organizer submission web form. Implement Ed25519 manifest signing. Set up the daily fetch + signature verification in the app. | Not started |
| J9 | **Geofence system** | Test CLLocationManager geofencing with real festival coordinates. Verify 2km detection radius, 15-minute periodic checks, and background location updates. Tune for battery efficiency. | Not started |
| J10 | **Crowd pulse data pipeline** | Implement the geohash-7 peer density aggregation. Test CrowdPulseOverlay with real mesh peer data. Ensure it updates smoothly as you walk through a venue. | Not started |

### P0 — Medical/SOS Backend

| # | Task | Description | Status |
|---|---|---|---|
| J11 | **Medical responder access codes** | Implement the organizer-issued rotating access code system. Codes in the festival manifest, verified locally, unlocks MedicalDashboardView. | Not started |

### P1 — Scalability & Performance

| # | Task | Description | Status |
|---|---|---|---|
| J14 | **Crowd-scale mode testing** | Simulate each crowd-scale mode (Gather/Festival/Mega/Massive) with varying peer counts. Verify mode transitions, TTL table changes, media restrictions, and relay probability adjustments. | Not started |
| J15 | **Traffic shaper tuning** | Test the 4-lane priority queue under load. Measure: lane bandwidth allocation (100%/60%/30%/10%), rate limiting (20pps in, 15pps out), burst behavior, backpressure at 80%/95%. | Not started |
| J16 | **Battery profiling** | Measure battery drain per crowd-scale mode over 8 hours (simulated festival day). Tune scan duty cycles and advertise intervals per power tier. Target: <50% drain at Festival mode. | Not started |
| J17 | **Fragmentation stress test** | Send large payloads (images, voice notes) over BLE. Verify fragmentation at 416-byte threshold, reassembly from out-of-order fragments, 30-second timeout, 128 concurrent assembly limit. | Not started |

### P1 — Data & SEO

| # | Task | Description | Status |
|---|---|---|---|
| J19 | **Festival database** | Build the initial festival database. Scrape/collect data for major festivals (coordinates, dates, stages, lineups). Structure as JSON manifest entries. Start with 10-20 festivals for launch. | Not started |
| J20 | **Landing page + SEO** | Build `blip.app` landing page. Optimise for: "festival chat app", "bluetooth mesh chat", "festival communication", "no signal festival app". Include App Store links, feature overview, download CTAs. | Not started |
| J21 | **App Store Optimization** | Research keywords, write optimized title/subtitle/description, plan screenshot strategy (coordinate with Tay on design). Target launch categories. | Not started |
| J22 | **Analytics infrastructure** | Set up privacy-respecting analytics (no PII, no message content). Track: DAU, mesh peer counts, crowd-scale mode distribution, message delivery rates, SOS usage, purchase conversion. | Not started |

### P2 — Hardening

| # | Task | Description | Status |
|---|---|---|---|
| J23 | **Reputation system testing** | Test block-vote tallying across a simulated cluster. Verify: 10 votes = deprioritize, 25 votes = drop broadcasts, SOS exempt, per-festival reset. | Not started |
| J24 | **Directed routing validation** | Test directed routing at Mega/Massive scale simulation. Verify routing table from neighbor lists, 5-minute entry expiry, fallback to gossip. Measure delivery improvement vs pure gossip. | Not started |
| J25 | **Push notification setup** | Configure APNs for internet-side message notifications when the app is backgrounded. Set up the lightweight push relay endpoint. | Not started |
| J25 | **Push notification setup** | Configure APNs for internet-side message notifications when the app is backgrounded. Set up the lightweight push relay endpoint. | Not started |

---

## Collaborative Tasks (Tay + John)

> These require both skill sets working together.

| # | Task | Owner | Description | Priority | Status |
|---|---|---|---|---|---|
| C1 | **Friend finder map** | Tay (design) + John (GPS/mesh data) | Tay designs the map pins, precision indicators, and "I'm here" beacon visuals. John wires up LocationService data, tests GPS accuracy, and ensures location packets deliver over mesh. | P0 | Not started |
| C2 | **Medical dashboard** | Tay (UI) + John (SOS data flow) | Tay designs the responder map, alert cards, and response workflow UI. John ensures SOS packets arrive reliably, GPS streams update in real-time, and the accept/navigate/resolve state machine works. | P0 | Not started |
| C3 | **Voice notes + PTT** | Tay (waveform UI) + John (audio encoding/streaming) | Tay polishes WaveformView and the recording UI. John handles Opus encoding, PTT packet streaming, and playback queue. | P1 | Not started |
| C4 | **Image sharing** | Tay (ImageViewer, thumbnails) + John (compression, fragmentation) | Tay polishes the image viewer (pinch-zoom, swipe dismiss). John handles JPEG compression to fit mesh MTU, fragmentation, and LRU cache. | P1 | Not started |
| C5 | **TestFlight beta** | Tay (screenshots, beta page) + John (provisioning, distribution) | Tay prepares beta invitation assets. John handles App Store Connect setup, provisioning profiles, and TestFlight distribution. | P1 | Not started |
| C6 | **Real festival field test** | Both | Take 5-10 devices to a real event. Test mesh formation, message delivery, SOS, friend finder, battery life. Document findings, file bugs, prioritize fixes. | P1 | Not started |

---

## Suggested Sprint Plan

### Sprint 1 (Weeks 1-2): Foundation
- **Tay**: T1, T2, T3, T4, T5, T22, T24
- **John**: J1, J2, J3, J4
- 14 tasks, 7 each

### Sprint 2 (Weeks 3-4): Core Features
- **Tay**: T6, T7, T8, T23, T25
- **John**: J5, J8, J9, J10, J11
- **Together**: C1, C2
- 12 tasks, balanced

### Sprint 3 (Weeks 5-6): Polish + Scale
- **Tay**: T9, T10, T11, T12, T26, T27
- **John**: J14, J15, J16, J17, J19
- **Together**: C3, C4
- 13 tasks, balanced

### Sprint 4 (Weeks 7-8): QA + Launch Prep
- **Tay**: T13, T14, T15, T16, T17, T18, T28
- **John**: J20, J21, J22, J23, J24, J25
- **Together**: C5, C6
- 15 tasks, balanced

---

## How to Pick Up a Task

1. Find an unstarted task in your lane
2. Change status to `In progress`
3. Create a branch: `tay/T1-onboarding-polish` or `john/J1-ble-testing`
4. Work, commit, push
5. Open a PR, tag the other person for review
6. Merge, mark task `Complete`

---

<p align="center">
  <strong>Tay makes it beautiful. John makes it work. Together, Blip.</strong>
</p>
