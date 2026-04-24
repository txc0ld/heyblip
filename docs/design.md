# Blip Mobile Design System

The visual language for Blip on iOS. Dark-first, glassmorphic, motion-rich.

---

## Colors

### Semantic Tokens

| Token | Dark | Light |
|---|---|---|
| Background | `#000000` | `#FFFFFF` |
| Text | `#FFFFFF` | `#000000` |
| Muted Text | `rgba(255,255,255,0.5)` | `rgba(0,0,0,0.5)` |
| Tertiary Text | `rgba(255,255,255,0.35)` | `rgba(0,0,0,0.35)` |
| Border | `rgba(255,255,255,0.08)` | `rgba(0,0,0,0.08)` |
| Card BG | `rgba(255,255,255,0.02)` | `rgba(0,0,0,0.02)` |
| Hover | `rgba(255,255,255,0.05)` | `rgba(0,0,0,0.05)` |

### Accents (same both themes)

| Token | Hex | RGB | Usage |
|---|---|---|---|
| Accent Purple | `#6600FF` | `102, 0, 255` | Primary brand, buttons, links, active states, tab indicators |
| Electric Cyan | `#00D4FF` | `0, 212, 255` | Sent status, online indicator, active connections |
| Warm Coral | `#FF6B6B` | `255, 107, 107` | SOS, errors, destructive actions, disconnect states |
| Mint | `#34D399` | `52, 211, 153` | Delivered/read receipts, success, connected, nearby peers |

### Status

| State | Color |
|---|---|
| Success / Online | `rgb(51, 214, 120)` |
| Warning / Pending | `rgb(255, 193, 7)` |
| Error / SOS | `rgb(255, 69, 69)` |

### Surface Hierarchy

**Dark:**

| Surface | Hex | Usage |
|---|---|---|
| Base | `#0A0A0F` | Page background |
| Elevated | `#12121A` | Elevated cards, sheets |
| Card | `#1A1A2E` | Card containers |
| Interactive | `#22223A` | Button/interactive backgrounds |

**Light:**

| Surface | Hex | Usage |
|---|---|---|
| Base | `#FAFAFE` | Page background |
| Elevated | `#FFFFFF` | Elevated cards, sheets |
| Card | `#F5F5FA` | Card containers |
| Interactive | `#EDEDF5` | Button/interactive backgrounds |

### Accent Gradient (3-stop)

```
startPoint: .topLeading → endPoint: .bottomTrailing
#6600FF → #8B5CF6 → #A78BFA
```

Used for: primary buttons, avatar rings, tab indicators, highlights.

### Ambient Washes (dark mode only)

| Wash | Color | Opacity |
|---|---|---|
| Purple | Accent Purple | 10% |
| Cyan | Electric Cyan | 6% |

---

## Typography

### Font

**Plus Jakarta Sans** — Regular, Medium, SemiBold, Bold.
Fallback: system font with rounded design.

### Scale

Mirror of `BlipTypography` (`Sources/DesignSystem/Typography.swift`). Every role ships as both a Plus Jakarta Sans variant and a system-font fallback; the active set is picked at runtime via `BlipFontRegistration.resolved` based on whether the custom font is registered.

| Role | Weight | Size | Dynamic Type | Usage |
|---|---|---|---|---|
| `display` | Bold | 40pt | `.largeTitle` | Splash / hero text |
| `largeTitle` | Bold | 34pt | `.largeTitle` | Navigation large titles |
| `title1` | SemiBold | 28pt | `.title` | Primary titles (alias of `title2` for legacy callers) |
| `title2` | SemiBold | 28pt | `.title2` | Modal / sheet titles |
| `title3` | SemiBold | 20pt | `.title3` | Section headers |
| `headline` | SemiBold | 22pt | `.headline` | Card headers |
| `callout` | SemiBold | 16pt | `.callout` | Action labels, callouts |
| `subheadline` | Medium | 15pt | `.subheadline` | Secondary labels |
| `body` | Regular | 17pt | `.body` | Body / chat text |
| `secondary` | Regular | 13pt | `.footnote` | Secondary / metadata |
| `footnote` | Regular | 13pt | `.footnote` | Footnote labels |
| `caption` | Medium | 11pt | `.caption2` | Captions |
| `captionSmall` | Medium | 9pt | `.caption2` | Tiny labels / timestamps |
| `caption2` | Medium | 10pt | `.caption2` | Small captions (legacy alias) |
| `micro` | Medium | 9pt | `.caption2` | Micro labels / status indicators (legacy alias) |

All sizes use `relativeTo:` for Dynamic Type scaling. Prefer the semantic role over hardcoded sizes in new code — the aliases exist only for backward compatibility.

---

## Spacing

4pt base unit. Defined in `BlipSpacing` (`Sources/DesignSystem/Spacing.swift`).

| Token | Value | Usage |
|---|---|---|
| `xxs` | 2pt | Fine optical tweaks, tight badge padding |
| `xs` | 4pt | Tight inline spacing, icon spacers |
| `sm` | 8pt | Inter-element spacing within components |
| `md` | 16pt | Standard content padding |
| `lg` | 24pt | Section spacing, card padding |
| `xl` | 32pt | Modal padding, hero sections |
| `xxl` | 48pt | Page-level spacing |

### Padding Presets

| Preset | Value |
|---|---|
| Card | 24pt all sides |
| Content | 16pt all sides |
| Horizontal | 16pt left/right only |

---

## Corner Radius

| Token | Value | Usage |
|---|---|---|
| `sm` | 8pt | Badges, chips |
| `md` | 12pt | Chat bubbles, small cards |
| `lg` | 16pt | Buttons, text fields |
| `xl` | 24pt | Primary cards, sheets |
| `xxl` | 32pt | Full-size modals |
| `capsule` | `.infinity` | Pill shapes (banners, tags) |

---

## Sizing

| Token | Value | Usage |
|---|---|---|
| Min tap target | 44pt | Apple HIG minimum |
| Icon button | 36pt | Standard icon buttons |
| Avatar small | 40pt | List items |
| Avatar medium | 56pt | Headers, chat |
| Avatar large | 80pt | Profile screen |
| Hairline | 0.5pt | Glass borders |

---

## Glassmorphism

### Materials

| Material | Blur | Usage |
|---|---|---|
| `.ultraThinMaterial` | ~8pt | Secondary glass, subtle backgrounds |
| `.regularMaterial` | ~16pt | Primary cards, floating elements |
| `.thickMaterial` | ~24pt | Overlays, modals, prominent surfaces |

### GlassCard Elevations

| Elevation | Material | Shadow Blur | Border Opacity | Shadow Opacity |
|---|---|---|---|---|
| Raised | ultraThin | 8pt | 15% | 15% |
| Floating | regular | 16pt | 25% | 25% |
| Overlay | thick | 24pt | 20% | 30% |

### Glass Effects

**Gradient border:**
- Dark: white 1.5x opacity (top-leading) to 0.3x (bottom-trailing)
- Light: black 0.3x (top-leading) to 1.2x (bottom-trailing)
- Width: 0.5pt hairline

**Inner glow:** 1pt stroke, white 4% (dark) / black 3% (light)

**Frosted noise:** Canvas-rendered, ~30% speckle density, 1pt dots, 2.5% opacity (dark) / 2% (light)

### Chat Bubbles

- Material: `.regularMaterial` or `.ultraThinMaterial`
- Border: 0.5pt white at 20% opacity
- Corner radius: 12pt
- Padding: 16pt horizontal, 12pt vertical

---

## Shadows

| Elevation | Blur | Y-Offset | Opacity (dark) | Opacity (light) |
|---|---|---|---|---|
| Raised | 8pt | 2pt | black 15% | black 7.5% |
| Floating | 16pt | 4pt | black 25% | black 12.5% |
| Overlay | 24pt | 6pt | black 30% + purple 4% | black 15% |
| Banner | 8pt | 4pt | black 15% | black 15% |

---

## Borders

| Element | Width | Color | Opacity |
|---|---|---|---|
| Glass card | 0.5pt | White/Black gradient | 15-25% |
| Inner glow | 1pt | White/Black | 3-4% |
| Chat bubble | 0.5pt | White | 20% |
| Component outline | 0.5pt | White/Black | 10-15% |
| Glass button | 0.5pt | White/Black gradient | 4-25% |

---

## Animation

### Springs

| Name | Stiffness | Damping | Usage |
|---|---|---|---|
| Page Entrance | 300 | 24 | Page transitions, staggered reveals |
| Message | 200 | 20 | Chat message slide-in |
| Bouncy | 400 | 18 | Toggles, badges, micro-interactions |
| Gentle | 150 | 20 | Fades, subtle movements |
| Snappy | 500 | 28 | Quick state changes |
| Elastic | 250 | 12 | Emoji reactions, badge pops |

All springs use mass = 1.0.

### Timing

| Duration | Value | Usage |
|---|---|---|
| Stagger delay | 50ms | Between list items |
| Fade | 250ms | Standard fades |
| Reveal | 450ms | Entrance animations (easeOut) |
| Shimmer cycle | 1.5s | Loading skeletons |
| Breathing ring | 3.0s | Mesh health indicator |
| Pulse glow | 2.0s | Active/recording state |
| Typing dots | 400ms | Per-dot pulse, 150ms offset |
| Liquid wave | 2.5s | Progress bar wave speed |
| Typewriter | 30ms | Per-character reveal, +/-8ms jitter |

### Reduce Motion

When `isReduceMotionEnabled`:
- Springs become instant (`linear(duration: 0.01)`)
- Staggered reveals become single fade
- Particles hidden or static
- Shimmer becomes static opacity
- Typewriter shows full text immediately

---

## Animation Components

### BreathingRing
Mesh health indicator. 1-5 rings based on connection strength.
- Base: 40pt, cycle 3.0s
- Scale oscillates 0.85-1.15 (sinusoidal)
- Ring spacing: 0.35x base size
- Opacity gradient: 80% (center) to 15% (outer)

### PulseGlow
Active/recording state. Default 60pt, accent purple, 2.0s cycle.
- Opacity: 0.3 to 0.8 (sinusoidal)
- Blur: 15% of size

### ParticleField
Ambient floating particles (dark mode only). 15-20 particles.
- Size: 1-3pt, 10-20% opacity
- Colors: accent purple or cyan (random)
- Drift: sinusoidal X/Y at 20fps
- Disabled in light mode

### WaveformView
Real-time audio visualization. Catmull-Rom spline, tension 0.3.
- Line: 2pt, fill at 15% opacity
- Top stroke full opacity, bottom mirrored at 50%
- Reduce motion: static bars

### MorphingIcon
Mic to send arrow transition. Bouncy spring.
- Scale 1.0 to 0.3, rotation +/-90 degrees, cross-fade

### RippleEffect
Expanding sonar rings for PTT. Default 3 rings, 1.5s cycle.
- Scale 1.0 to 2.5, opacity 0.7 to 0.0

### ShimmerModifier
Glass loading skeleton. 1.5s cycle.
- White 8% opacity sweep, 60% width

### ElasticCounter
Animated number changes. Scale pop 1.0 to 1.15 on elastic spring.

### StaggeredReveal
View modifier (`.staggeredReveal(index:)`) used on list items to cascade entrance animations. Applies the page-entrance spring with a `staggerDelay` (50ms) per index.

### ScrollReveal
Fade + translate-up animation triggered when a view enters the visible scroll area. 450ms easeOut; respects Reduce Motion (instant fade-in).

### LiquidProgress
Animated wave-fill progress bar. 2.5s wave cycle, accent-gradient fill, used for long-running transfers (voice note uploads, image downloads).

### TypewriterText
Character-by-character text reveal. 30ms per character with +/-8ms jitter to feel organic. Reduce Motion reveals the full string immediately.

---

## Buttons

### Styles

| Style | Background | Border | Text |
|---|---|---|---|
| Primary | Accent gradient | None | White |
| Secondary | `.ultraThinMaterial` | 0.5pt gradient | Theme text |
| Outline | Transparent | 1pt accent gradient | Theme text |

### Sizes

| Size | V-Pad | H-Pad | Font | Min Height |
|---|---|---|---|---|
| Small | 8pt | 16pt | Medium 13pt | 44pt |
| Regular | 14pt | 24pt | SemiBold 15pt | 44pt |
| Large | 16pt | 32pt | SemiBold 17pt | 44pt |

### Press Animation

Scale 1.0 -> 0.985 (response 0.20, damping 0.65) -> 1.002 overshoot (after 150ms) -> 1.0 settle.

---

## Avatars

### Ring Styles

| Ring | Appearance | Animation |
|---|---|---|
| None | No ring | -- |
| Friend | Accent gradient, 2pt | Static |
| Nearby | Green, pulsing | Scale 1.0-1.15, 1.5s |
| Subscriber | Accent gradient, 2.5pt | Static |

Ring width: `max(2pt, size x 0.04)`

### Online Dot

- Color: Electric Cyan (`#00D4FF`)
- Size: 25% of avatar diameter
- Border: 2pt white (dark) / black (light)
- Position: bottom-right

### Initials Fallback

- Gradient from name hash (HSL)
- Font: system rounded semi-bold, 42% of avatar size
- Max 2 characters, white text

---

## Status Badge (Message Delivery)

| State | Icon | Color |
|---|---|---|
| Composing | 3 glass dots | -- |
| Queued | Clock | Muted |
| Encrypting | Lock | Muted |
| Failed | Exclamation | Warm Coral |
| Sent | Single check | Electric Cyan |
| Delivered | Double checks | Mint |
| Read | Bold double checks | Mint |

---

## Gradient Background

### Dark Mode (3 layers)

1. **Base:** Linear gradient surfaceBase to black
2. **Ambient washes:** Purple radial (400pt, 10%) + Cyan radial (350pt, 6%), screen blend
3. **Animated orbs:** 3 drifting radial gradients (purple, blue, teal), 12s cycle

Orb colors:
- Deep purple: `rgb(38, 0, 89)`
- Midnight blue: `rgb(13, 13, 64)`
- Dark teal: `rgb(0, 31, 51)`

### Light Mode

Base linear gradient + ambient washes only (multiply blend). No orbs.

---

## Accessibility

- Minimum tap target: 44pt
- All interactive elements: `.accessibilityLabel()`
- Dynamic Type: all text scales with system preference
- Reduce motion: all animations gracefully degrade
- Status colors meet WCAG AA contrast
