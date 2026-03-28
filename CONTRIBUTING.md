# Contributing to FestiChat

FestiChat is currently in private development. This document outlines the standards for contributing code.

## Code Standards

- **Swift 5.9+** with strict concurrency
- **SwiftUI** for all UI — no UIKit unless wrapping unavailable capability
- **@Observable** (iOS 17+) for all ViewModels
- **SwiftData** for persistence
- No force unwraps (`!`), no `var` when `let` suffices
- `private` access control by default
- All views must include `#Preview` blocks
- All interactive elements: 44pt minimum tap targets, VoiceOver labels
- Respect `UIAccessibility.isReduceMotionEnabled` in all animations

## Design Tokens

- **Font**: Plus Jakarta Sans (Regular 400, Medium 500, SemiBold 600, Bold 700)
- **Accent**: `#6600FF`
- **Materials**: `.ultraThinMaterial`, `.regularMaterial`, `.thickMaterial`
- **Corner radius**: 24pt for cards, 16pt for buttons, 12pt for small elements

## Git Conventions

- **Conventional commits**: `type(scope): description`
- Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `perf`, `security`
- One logical change per commit
- Never commit with failing tests

## Testing

- Protocol package: `swift test --package-path Packages/FestiChatProtocol`
- Crypto package: `swift test --package-path Packages/FestiChatCrypto`
- Mesh package: `swift test --package-path Packages/FestiChatMesh`

All PRs must pass existing tests and include tests for new functionality.

## Architecture Rules

- All mesh/crypto complexity is invisible to the user
- Transport selection is always automatic (BLE first, WebSocket fallback)
- Encryption is always on — no toggle, no "start encrypted chat"
- SOS packets are never throttled at any crowd scale
- The binary protocol spec (`docs/PROTOCOL.md`) is the cross-platform contract
