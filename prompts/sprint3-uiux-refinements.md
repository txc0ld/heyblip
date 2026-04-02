# Claude Code Prompt — Sprint 3: UI Buildout + Mobile Polish + Neon Backend

Paste this into your Claude Code terminal session.

---

```
Read CLAUDE.md, then read the design spec at docs/superpowers/specs/2026-03-28-blip-design.md in full. You are building out app interfaces, wiring real data, polishing the mobile experience, and standing up the Neon backend.

## Setup

1. git checkout main && git pull origin main
2. git checkout -b tay/sprint3-ui-buildout
3. xcodegen generate

## Scope

Frontend views, design system, view models, models, and the Cloudflare Worker backend. No changes to BLE/mesh packages (BlipProtocol, BlipMesh, BlipCrypto).

---
---

## PHASE 0 — AUDIT (mandatory, do this before writing any code)

Before touching ANY file, audit the existing design system and document what exists. This prevents introducing inconsistencies.

Scan and catalog:
1. **Colors** — Read Sources/DesignSystem/Colors.swift. Map every semantic token (fcBackground, fcText, fcMutedText, fcBorder, fcCardBG, fcHover, fcAccentPurple, status colors). Check Asset Catalog for named colors. Grep all view files for hardcoded hex/rgb values that bypass tokens.
2. **Typography** — Read Sources/DesignSystem/Typography.swift. Map every text style (fcLargeTitle, fcHeadline, fcBody, fcSecondary, fcCaption). Grep for raw `.font(.system(...))` calls that bypass the type system.
3. **Spacing** — Read Sources/DesignSystem/Spacing.swift. Map FCSpacing scale (xs/sm/md/lg/xl/xxl), FCCornerRadius, FCSizing. Grep for magic number padding/spacing that bypasses tokens.
4. **Existing patterns** — Read GlassCard.swift, GlassButton.swift, GradientBackground.swift, Theme.swift. Document material usage, border treatments, corner radii, shadow patterns, spring constants already in use.
5. **Component inventory** — List every shared component in Sources/Views/Shared/. Note which views use them vs roll their own.
6. **Motion inventory** — Read Sources/Animations/. Document existing spring constants, easing curves, stagger values.

Print the audit summary before proceeding. Do NOT begin code changes until the audit is complete.

---
---

## PART A — SOS RELOCATION & ICON CHANGE (do this first)

### A1. Move SOS to Profile screen

In ProfileView.swift:
- Add the SOS button prominently at the top of the profile screen (below avatar section, above the quick actions grid)
- The button should be full-width, glass surface, 60pt minimum tap target
- On tap → present SOSConfirmationSheet as .fullScreenCover

### A2. Change SOS icon — remove text, use medical cross only

In SOSButton.swift:
- Remove the "SOS" text label entirely
- Replace `cross.circle.fill` with `cross.case.fill` (medical bag with cross) — this is the clearest medical symbol in SF Symbols. If unavailable on iOS 17, fall back to `plus.circle.fill`
- Keep the red color treatment, press animation, and accessibility label ("Emergency")
- Icon-only: red medical cross on glass, no text, no label

### A3. Wire SOSButton to real SOSConfirmationSheet

- SOSButton currently opens a placeholder. Wire it to present the real SOSConfirmationSheet (already fully built with 3-tier severity)
- Remove the SOSConfirmationPlaceholder struct entirely
- Remove any SOS presence from MainTabView or other tab-level placements

---

## PART B — THEME MODE SWITCHER

### B1. Proper theme switching with System/Light/Dark

SettingsView already has a theme picker but it's a local @State. Make it production-ready:

Create an AppTheme enum in Sources/Models/ (or extend existing):
```swift
enum AppTheme: String, CaseIterable, Codable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil  // follow device
        case .light: return .light
        case .dark: return .dark
        }
    }
}
```

Wire it:
- Store as @AppStorage("appTheme") defaulting to .system
- Apply in BlipApp.swift (or the root view) using `.preferredColorScheme(appTheme.colorScheme)` — when nil, the system preference is respected
- In SettingsView: replace the current theme segmented picker with one that binds to this @AppStorage value
- Add a subtle icon next to each option: `moon.fill` (dark), `sun.max.fill` (light), `gearshape.fill` (system)
- The picker change should take effect immediately — no restart, no delay

### B2. Theme-aware transitions

When the user switches theme:
- Animate the color scheme change with a smooth crossfade (`.animation(.easeInOut(duration: 0.3), value: appTheme)`)
- Ensure ALL glass materials, borders, muted text, and card backgrounds adapt correctly in both modes (this gets verified in Phase 3)

---

## PART C — PROFILE SCREEN BUILDOUT

### C1. Wire ProfileView to SwiftData

Replace all hardcoded mock data:
- @Query for the current User from SwiftData (single local user)
- Display real: username, displayName, bio, avatarThumbnail, message balance
- Friend count from user.friends relationship
- If no user found → empty state with "Complete Setup" CTA

### C2. Verified Profile Badge ($14.99)

Add `isVerified: Bool` field to User model (default false).

In ProfileView:
- Verified: purple `checkmark.seal.fill` badge overlay on avatar, subtle glow ring
- Not verified: "Get Verified" glass button in profile header

Create VerifiedProfileSheet.swift:
- Glass sheet with benefits explanation
- Benefits: purple badge, priority in Nearby, trust indicator in chat
- Price display: $14.99 one-time
- CTA → StoreKit 2 purchase of `com.blip.verified`
- On success: user.isVerified = true, save, dismiss
- Add product ID to StoreViewModel.swift

### C3. Edit Profile — wire to persistence

In EditProfileView.swift:
- Save displayName, username, bio, avatar to SwiftData on "Save"
- Add masked email display (read-only: "t***@gmail.com") with verified checkmark
- "Change Email" re-triggers verification flow

---

## PART D — SETTINGS BUILDOUT

### D1. Transport Mode Toggle (new "Network" group, after Appearance)

```
Network
├─ Transport Mode (segmented picker)
│   ├─ "BLE Only" — mesh only, zero internet (event mode)
│   ├─ "BLE + WiFi" — mesh + WiFi relay
│   └─ "All Radios" — BLE + WiFi + Cellular (default)
├─ Toggle: "Auto Event Mode" — auto-switch to BLE Only in event geofence
└─ Caption: "BLE Only saves battery and works offline. Messages route through nearby devices."
```

Create TransportMode enum in Sources/Models/:
```swift
enum TransportMode: String, CaseIterable, Codable {
    case bleOnly = "BLE Only"
    case bleAndWifi = "BLE + WiFi"
    case allRadios = "All Radios"
}
```

Store in @AppStorage("transportMode"), default .allRadios.

Add SF Symbol icons to each option: `antenna.radiowaves.left.and.right.slash` (BLE Only), `wifi` (BLE+WiFi), `antenna.radiowaves.left.and.right` (All Radios).

### D2. Wire ALL existing settings to @AppStorage

Every toggle/picker in SettingsView is currently local @State. Wire to @AppStorage:
- appTheme → @AppStorage("appTheme") (from Part B)
- locationPrecision → @AppStorage("locationPrecision")
- proximityAlerts → @AppStorage("proximityAlerts")
- breadcrumbTrails → @AppStorage("breadcrumbTrails")
- crowdPulse → @AppStorage("crowdPulse")
- pushNotifications → @AppStorage("pushNotifications")
- autoJoinChannels → @AppStorage("autoJoinChannels")
- pttMode → @AppStorage("pttMode")
- transportMode → @AppStorage("transportMode")

### D3. Account section additions

Add to the Account section:
- "Sign Out" button — clears local session, returns to onboarding (separate from Delete)
- "Export My Data" — exports User profile as JSON to Files via ShareLink

---

## PART E — MESSAGE PACK STORE — WIRE TO REAL STOREKIT

### E1. Connect MessagePackStore UI to StoreViewModel

Kill the mock 1s delay:
- On appear: storeViewModel.loadProducts()
- Display real App Store prices (not hardcoded)
- Purchase → storeViewModel.purchase(product)
- Purchasing spinner during transaction
- Balance from storeViewModel.messageBalance
- Restore purchases button at bottom

### E2. Verified Profile product in store

Featured section at top of MessagePackStore:
- Purple accent glass card, distinct from message packs
- "One-time purchase · $14.99"
- If already verified: "Verified ✓" muted, non-tappable

---

## PART F — EMAIL DATABASE + NEON BACKEND

### F1. Extend Cloudflare Worker (server/auth/src/index.ts)

Add Neon Postgres via `@neondatabase/serverless`:
- Connection string from `DATABASE_URL` secret in wrangler.toml

New endpoints:

`POST /v1/users/register`
- Body: `{ emailHash, username, createdAt, isVerified }`
- Insert into `users` table. Return `{ userId }`.
- No raw email — SHA256 hash only.

`POST /v1/users/sync`
- Upsert by emailHash: isVerified, messageBalance, lastActiveAt

`GET /v1/users/:emailHash`
- Return profile for account recovery

`POST /v1/receipts/verify`
- StoreKit 2 JWS transaction validation
- On verified purchase: update Neon (isVerified or balance)
- Return `{ valid, balance, isVerified }`

Schema (server/auth/schema.sql):
```sql
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email_hash VARCHAR(64) UNIQUE NOT NULL,
    username VARCHAR(32) UNIQUE NOT NULL,
    is_verified BOOLEAN DEFAULT FALSE,
    message_balance INTEGER DEFAULT 0,
    last_active_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_users_email_hash ON users(email_hash);
CREATE INDEX idx_users_username ON users(username);
```

### F2. iOS client service

Create UserSyncService.swift in Sources/Services/:
- `registerUser(emailHash:username:)` — after onboarding
- `syncProfile()` — on app launch when online
- `verifyReceipt(transactionJWS:)` — after StoreKit purchase
- All calls gated on TransportMode — skip if .bleOnly
- Offline queue: retry when connectivity returns

Wire in:
- CreateProfileStep → fire-and-forget registerUser() after SwiftData insert
- StoreViewModel → verifyReceipt() after successful purchase

### F3. Tests

server/auth/test/:
- Register: valid, duplicate emailHash, duplicate username, missing fields
- Sync: upsert, partial updates
- Receipt verify: valid/invalid
- Rate limiting

---
---

## PART G — MOBILE POLISH (the premium feel)

This is where Blip goes from "works" to "feels incredible." Apply these using ONLY the design tokens from the Phase 0 audit. Do NOT introduce new colors or fonts.

### G1. Screen Entrance Choreography (highest-impact single change)

Every primary screen gets an orchestrated staggered reveal on first appearance. This is the #1 thing that makes an app feel premium.

**Pattern** (apply to every tab's root view):
```swift
// Each element gets an index-based delay
.opacity(appeared ? 1 : 0)
.offset(y: appeared ? 0 : 20)
.animation(
    .spring(Spring(stiffness: 300, damping: 24))
    .delay(Double(index) * 0.05),  // 50ms stagger
    value: appeared
)
```

Apply to:
- **ProfileView**: avatar → name → bio → SOS button → quick actions grid (5 elements, 250ms total)
- **ChatListView**: search bar → first cell → second cell → ... (cells stagger in)
- **NearbyView**: mesh status bar → peer cards stagger in
- **EventView**: header → stage map → schedule section → announcements
- **MainTabView**: tab bar slides up on first launch

Check `UIAccessibility.isReduceMotionEnabled` — if true, show everything immediately with a simple 0.2s opacity fade, no translation.

### G2. Scroll-Triggered Reveals

As user scrolls, off-screen sections fade/slide in when they enter the viewport:

```swift
// Use GeometryReader inside a LazyVStack to detect visibility
GeometryReader { geo in
    let minY = geo.frame(in: .global).minY
    let screenHeight = UIScreen.main.bounds.height
    let isVisible = minY < screenHeight * 0.85

    content
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 24)
        .animation(.spring(Spring(stiffness: 300, damping: 24)), value: isVisible)
}
```

Apply to:
- Settings sections (each group reveals as scrolled to)
- Chat messages (already have spring slide-in — verify it works)
- Nearby peer cards
- Event tab sections
- Friend Finder bottom sheet friend list
- MessagePackStore pack cards

### G3. Interactive Feedback — Haptics + Micro-animations

Every tappable surface needs tactile feedback:

**Buttons (all GlassButton instances):**
- Already have press scale (0.97). Verify all instances use it.
- Add `.sensoryFeedback(.impact(flexibility: .soft), trigger: isTapped)` (iOS 17+)

**Cards / List cells:**
- Subtle scale on press: `.scaleEffect(isPressed ? 0.98 : 1.0)` with `.animation(.spring(duration: 0.2))`
- Light haptic on tap: `.sensoryFeedback(.selection, trigger: tapCount)`

**Toggle switches:**
- `.sensoryFeedback(.selection, trigger: toggleValue)` on every Toggle in Settings

**Tab bar:**
- Light impact haptic on tab switch
- Subtle scale bounce on selected tab icon (1.0 → 1.15 → 1.0, spring)

**Pull-to-refresh (if applicable):**
- Haptic tick when threshold reached

**SOS button:**
- Heavy haptic on press (already exists — verify)
- Escalating haptic pattern during hold-to-confirm (already in SOSConfirmationSheet — verify)

### G4. First Viewport Budget — Hero Discipline

Each tab's first screen (before scroll) must be clean and focused. Audit and enforce:

**ChatListView first viewport:**
- Navigation title + search bar + first 3-4 chat cells
- No stat strips, no promotional banners, no feature callouts
- Empty state: single icon + "No conversations yet" + "Find people nearby" CTA

**NearbyView first viewport:**
- Mesh status indicator (connected peers count) + first 2-3 peer cards
- No clutter above the peer list

**ProfileView first viewport:**
- Avatar + name + bio + SOS button + quick actions grid
- This IS the hero — the avatar section should feel spacious, not cramped
- Verified badge should have breathing room

**EventView first viewport:**
- Event name/header + stage map (full-width, edge-to-edge if possible)
- Schedule and announcements below the fold

### G5. Visual Hierarchy & Spacing Rhythm

**Remove visual clutter:**
- Eliminate any double-borders (card inside card, bordered element inside bordered section)
- Remove redundant labels (if a section title says "Friends", the count badge doesn't also need a "friends" label)
- Collapse competing text blocks — one headline + one supporting line per section max

**Enforce spacing rhythm:**
- Use the existing FCSpacing scale consistently
- Section gaps: FCSpacing.xl (32pt) between major sections
- Internal card padding: FCSpacing.md (16pt)
- List cell spacing: FCSpacing.sm (8pt)
- Verify no section has tighter spacing than the one above it (spacing should be consistent or increase as you scroll)

**Card discipline:**
- Cards are for interactive containers only (tappable items, selection groups)
- If removing a card's border + background doesn't hurt comprehension → remove the card treatment
- No cards inside cards (nesting)

### G6. Glass Surface Hierarchy (3-tier system)

Enforce consistent material usage across all views:

| Surface level | Material | Use case |
|---|---|---|
| Background (level 0) | Solid fcBackground or GradientBackground | App background, onboarding |
| Elevated (level 1) | .ultraThinMaterial | Tab bar, nav bar, bottom sheets |
| Card (level 2) | .regularMaterial + 0.5pt border at fcBorder | Chat bubbles, peer cards, settings groups |
| Modal (level 3) | .thickMaterial + cornerRadius(24) | Sheets, alerts, overlays, SOS confirmation |

Audit every view and fix any surface that uses the wrong tier. Common mistakes:
- Cards using .thickMaterial (too heavy, should be .regularMaterial)
- Sheets using .ultraThinMaterial (too transparent, should be .thickMaterial)
- Tab bar using opaque background (should be .ultraThinMaterial)

### G7. Transition Polish

**Sheet presentations:**
- All `.sheet` and `.fullScreenCover` should animate with spring (not default linear)
- Use `.presentationDetents([.medium, .large])` where appropriate (friend list, message packs)
- Add `.presentationDragIndicator(.visible)` on all sheets
- Sheets should have `.presentationBackground(.ultraThinMaterial)` for glass effect

**Navigation transitions:**
- Chat list → Chat view: default push (keep native)
- Profile → Edit Profile: sheet from bottom
- Any → Full screen image: `.fullScreenCover` with custom zoom transition if feasible

**Tab transitions:**
- Content should crossfade between tabs, not jump
- Use `.transition(.opacity)` on tab content

### G8. Loading States — Glass Skeleton Shimmer

Replace every bare `ProgressView()` with a branded loading state:

Create a ShimmerModifier in Sources/DesignSystem/:
```swift
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.1), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: phase)
                .animation(.linear(duration: 1.5).repeatForever(autoreverses: false), value: phase)
            )
            .onAppear { phase = 300 }
    }
}
```

Apply to:
- Chat list: 3-4 placeholder glass cells with shimmer
- Nearby: 2-3 placeholder peer cards with shimmer
- Event: placeholder stage map rect + 2 schedule bars
- Profile: avatar circle + 2 text bars + 4 action squares

### G9. Empty States — Personality, Not Just Text

Every empty state should feel intentional, not broken:

| Screen | Icon | Title | Subtitle | CTA |
|---|---|---|---|---|
| Chat list | `bubble.left.and.bubble.right` | "No conversations yet" | "Find people nearby to start chatting" | "Go to Nearby" (switches tab) |
| Nearby | `antenna.radiowaves.left.and.right` | "Scanning for people..." | "Make sure Bluetooth is on" | "Open Settings" (deep link) |
| Event | `party.popper` (or `music.note.house`) | "No active event" | "Join a event to see stages, schedules, and friends" | None (informational) |
| Friends | `person.2` | "No friends yet" | "Add friends from Nearby or share your QR code" | "Share QR" |
| Messages (in chat) | `text.bubble` | "Say hello!" | "Messages are end-to-end encrypted via mesh" | None (text input is the CTA) |

Style: centered, muted icon (48pt, fcMutedText), title in fcHeadline, subtitle in fcSecondary + fcMutedText, CTA as GlassButton(.secondary).

### G10. Error States — Calm, Not Alarming

Error states use a glass card, never a red banner:
- Glass card (level 2) with warning icon `exclamationmark.triangle` in fcAmber (not red)
- Title: what happened ("Connection lost", "Couldn't load messages")
- Subtitle: what to do ("Pull down to retry", "Check your Bluetooth settings")
- "Try Again" GlassButton(.secondary)
- No stack traces, no error codes, no alarming language

---
---

## PART H — ACCESSIBILITY + DARK/LIGHT VERIFICATION

### H1. Full Accessibility Pass

- Every interactive element: `.accessibilityLabel()` + `.accessibilityHint()` where non-obvious
- Images: `.accessibilityLabel()` descriptions
- Group related elements: `.accessibilityElement(children: .combine)`
- Dynamic Type: test with `.environment(\.sizeCategory, .accessibilityExtraExtraLarge)` — layouts must not break
- `.accessibilityAddTraits(.isButton)` on tappable non-Button elements
- SOS: `.accessibilityAddTraits(.startsMediaSession)` (signals urgency to VoiceOver)

### H2. Dark/Light Mode Verification

After all changes, verify EVERY view in both color schemes:
- All colors resolve through semantic tokens
- Glass materials adapt correctly (darker in dark mode, lighter in light)
- Border opacities: dark = white at 8%, light = black at 8%
- Muted text: dark = white 50%, light = black 50%
- No white-on-white or black-on-black text
- Verified badge glow visible in both modes
- SOS red reads clearly on both backgrounds

---
---

## Rules

- Max ~200 lines per view file — extract subviews into private extensions
- #Preview blocks on every view you touch (both light and dark: `#Preview("Dark") { ... .preferredColorScheme(.dark) }`)
- No UIKit, no third-party UI libs, no force unwraps
- All new colors through Colors.swift, all new fonts through Typography.swift
- ZERO new colors or fonts — use only what exists in the design system from Phase 0 audit
- New Swift files: create them, list them in PR, I'll add via XcodeGen
- New server dependencies: add to server/auth/package.json
- Build after each logical batch: `xcodebuild -scheme Blip -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet 2>&1`
- Backend tests: `cd server/auth && npm test`

## Commit Strategy

Multiple focused commits (don't batch everything):
1. `refactor(sos): relocate SOS to profile, medical cross icon, wire real confirmation sheet`
2. `feat(theme): system/light/dark mode switcher with animated transitions`
3. `feat(profile): wire SwiftData, verified badge, edit persistence`
4. `feat(settings): transport mode, persist all settings, sign out, export data`
5. `feat(store): wire MessagePackStore to real StoreKit, add verified product`
6. `feat(backend): Neon user database, registration, sync, receipt validation`
7. `feat(ui): screen entrance choreography, scroll reveals, haptic feedback`
8. `feat(ui): glass surface hierarchy, shimmer loading, empty/error states`
9. `fix(ui): glassmorphism audit, typography tokens, spacing rhythm, accessibility`

## Deliverable

After all commits:
1. Push: git push -u origin tay/sprint3-ui-buildout
2. Create PR:

gh pr create --title "Sprint 3: UI buildout, mobile polish, Neon backend" --body "$(cat <<'EOF'
## Summary

### Features
- SOS relocated to Profile screen — medical cross icon, no text, wired to real confirmation sheet
- Theme switcher: System / Light / Dark with animated transitions, persisted to @AppStorage
- Profile wired to SwiftData — verified badge ($14.99 IAP), edit persistence, masked email
- Settings: transport mode (BLE Only / BLE+WiFi / All Radios), all toggles persisted, sign out, export data
- MessagePackStore wired to real StoreKit 2, verified profile product featured
- Neon Postgres backend: user registration, profile sync, receipt validation via Cloudflare Worker

### Mobile Polish
- Screen entrance choreography: staggered spring reveals on every primary screen
- Scroll-triggered reveals: sections animate in as they enter viewport
- Haptic feedback: impact on buttons, selection on toggles, escalating on SOS
- Glass surface hierarchy: 3-tier material system enforced across all views
- Shimmer loading states replacing bare ProgressView
- Personality-driven empty states with contextual CTAs
- Calm glass error cards (amber warning, not red alarm)
- Sheet presentation polish: spring animations, drag indicators, glass backgrounds
- Tab crossfade transitions

### Backend
- `POST /v1/users/register` — persist user on signup
- `POST /v1/users/sync` — periodic profile sync when online
- `GET /v1/users/:emailHash` — account recovery
- `POST /v1/receipts/verify` — StoreKit receipt validation

### Quality
- Glassmorphism audit: all surfaces match design spec material tiers
- Typography: all text uses design tokens, zero raw .font(.system()) calls
- Spacing: all values use FCSpacing/FCCornerRadius, zero magic numbers
- Dark/light mode verified across every view
- Accessibility: labels, hints, Dynamic Type, VoiceOver, reduced motion

## Test plan
- [ ] iOS build passes
- [ ] Backend tests pass (npm test)
- [ ] SOS button on Profile — medical cross, no text
- [ ] Theme switcher: System/Light/Dark works, persists, animates
- [ ] Profile shows real SwiftData user with verified badge flow
- [ ] Transport mode picker persists between launches
- [ ] Message pack purchase flows through StoreKit
- [ ] Screen entrance animations play on fresh navigation
- [ ] Reduced motion: all animations collapse to simple fades
- [ ] Dark mode visual check (all views)
- [ ] Light mode visual check (all views)
- [ ] Dynamic Type at XXL — no broken layouts
- [ ] VoiceOver full navigation path
EOF
)"

3. Print the PR URL and full summary of files changed/created
```
