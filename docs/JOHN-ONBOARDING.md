# HeyBlip — John's Onboarding Guide

Hey John, welcome to HeyBlip. Here's everything you need to get started.

---

## 1. Clone the repo

```bash
git clone https://github.com/txc0ld/FezChat.git
cd FezChat
```

## 2. Read these files first (in this order)

| File | What it is | Time |
|---|---|---|
| `README.md` | Project overview, architecture, tech stack | 5 min |
| `WORKPLAN.md` | Your tasks are in the **"John"** section | 10 min |
| `docs/WHITEPAPER.md` | How the mesh network works | 10 min |
| `docs/PROTOCOL.md` | Binary protocol spec (you'll need this for server work) | 15 min |
| `docs/superpowers/specs/2026-03-28-blip-design.md` | Full design spec (1,500+ lines, reference as needed) | Skim 20 min |
| `CLAUDE.md` | Instructions that Claude/Codex auto-loads when working in this repo | 5 min |
| `CONTRIBUTING.md` | Code standards, git conventions | 5 min |

## 3. Your task list

Your tasks are all prefixed with **J** in `WORKPLAN.md`. Start with **P0 Sprint 1**:

- **J1** — BLE mesh integration testing (real devices)
- **J2** — Gossip routing real-world test (5+ devices)
- **J3** — Phone verification backend (Twilio/Firebase)
- **J4** — WebSocket relay server (Cloudflare Workers)

## 4. Using Claude Code / Codex

### Option A: Claude Code (CLI)

```bash
# Install if you don't have it
npm install -g @anthropic-ai/claude-code

# Navigate to the repo
cd FezChat

# Start Claude Code — it auto-loads CLAUDE.md
claude
```

Then tell it what to work on:

```
Read WORKPLAN.md and start on task J1 — BLE mesh integration testing.
Read the relevant spec sections before starting.
```

### Option B: Codex (OpenAI)

```bash
cd FezChat
codex
```

It will auto-load `AGENTS.md` and `AGENTS.override.md`. Tell it:

```
Read WORKPLAN.md. I am John. Start on my P0 Sprint 1 tasks.
Follow the execution lifecycle in AGENTS.md.
```

### Option C: Claude Desktop (Cowork)

1. Open Claude Desktop
2. Open Cowork
3. Select the `FezChat` folder
4. It auto-loads `CLAUDE.md`
5. Tell it: "Read WORKPLAN.md. I'm John. Start on J1."

### Paste this into your LLM's first message:

```
I am John, working on the HeyBlip project (internal codename Blip, BLE mesh chat app for events).

My role: Backend, data, infrastructure, SEO.

Read these files in order:
1. README.md — project overview
2. WORKPLAN.md — find ALL tasks prefixed with "J" (those are mine)
3. CLAUDE.md — project rules and build commands
4. docs/PROTOCOL.md — binary protocol spec
5. docs/superpowers/specs/2026-03-28-blip-design.md — full design spec

Start with my P0 Sprint 1 tasks (J1-J4). For each task:
1. Read the relevant spec sections
2. Create a branch: john/J{number}-{short-description}
3. Implement
4. Test
5. Commit with conventional format: type(scope): description
6. Push and open a PR

Work autonomously. Don't ask questions the codebase or spec can answer.
```

## 5. Branch naming

```
john/J1-ble-mesh-testing
john/J2-gossip-routing-test
john/J3-phone-verification
john/J4-websocket-relay
```

## 6. Key technical context for your tasks

### J1 — BLE mesh testing
- `Packages/BlipMesh/Sources/BLEService.swift` — dual-role BLE implementation
- Service UUID: `FC000001-0000-1000-8000-00805F9B34FB`
- Needs 3+ iPhones running the app simultaneously
- Test: peer discovery, connection, data exchange, state restoration after backgrounding

### J2 — Gossip routing
- `Packages/BlipMesh/Sources/GossipRouter.swift` — core routing
- `Packages/BlipProtocol/Sources/BloomFilter.swift` — dedup
- Test with 5+ devices in a line: send from device 1, verify delivery at device 5 via hops

### J3 — Phone verification backend
- `Sources/Services/PhoneVerificationService.swift` — client-side code already written
- You need to build the server endpoint it calls
- Twilio Verify API or Firebase Auth
- Rate limiting: 60s cooldown, 5 sends/hour, 5 verify attempts

### J4 — WebSocket relay server
- `Packages/BlipMesh/Sources/WebSocketTransport.swift` — client-side code exists
- Endpoint: `wss://relay.blip.app/ws`
- Auth: Noise public key as Bearer token
- Receives binary protocol packets, forwards by recipient PeerID
- Stores NOTHING — zero-knowledge relay
- Suggested: Cloudflare Workers with Durable Objects

### J5 — Event manifest
- `Sources/ViewModels/EventViewModel.swift` — client fetch code exists
- JSON format defined in spec Section 9.2
- Needs Ed25519 manifest signing (key embedded in app binary)
- Host on GitHub Pages or CDN

### J8 — Event manifest system
- Build the organizer web form for submitting events
- Output: signed JSON manifest with event data, stage maps, schedules

## 7. Build commands

```bash
# Generate Xcode project (need xcodegen installed)
brew install xcodegen
xcodegen generate

# Build
xcodebuild -scheme Blip -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -quiet

# Run package tests
swift test --package-path Packages/BlipProtocol
swift test --package-path Packages/BlipCrypto
swift test --package-path Packages/BlipMesh
```

## 8. Architecture quick reference

```
Packages/
  BlipProtocol/   — Binary wire format (you'll reference this a lot)
  BlipCrypto/     — E2E encryption (Noise XX)
  BlipMesh/       — BLE transport + routing (your main territory)

Sources/
  Models/              — 21 SwiftData models
  Services/            — Business logic (MessageService, LocationService, etc.)
  ViewModels/          — @Observable view models
  Views/               — SwiftUI (Tay's territory mostly)

docs/
  PROTOCOL.md          — Cross-platform binary spec (your bible for server work)
  WHITEPAPER.md        — Project overview
```

## 9. Questions?

Don't ask Tay unless it's about UI/design decisions. For everything else:
- Check the design spec first (`docs/superpowers/specs/2026-03-28-blip-design.md`)
- Check the protocol spec (`docs/PROTOCOL.md`)
- Check the existing code
- If genuinely blocked, create a GitHub issue

Let's build this.

— Tay
