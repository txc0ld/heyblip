# HEY-1267 Chat UI Polish

## Plan
- [x] Read `CLAUDE.md` first
- [x] Read repo instruction chain and relevant design guidance
- [x] Inspect the four target files and confirm current implementations

## Fixes
- [x] Fix 1: Dismiss keyboard on send in `Sources/Views/Tabs/ChatsTab/MessageInput.swift`
- [x] Fix 2: Dismiss keyboard when opening attachment menu in `Sources/Views/Tabs/ChatsTab/MessageInput.swift`
- [x] Fix 3a: Add reduce-motion-guarded send haptic in `Sources/Views/Tabs/ChatsTab/MessageInput.swift`
- [x] Fix 3b: Add reduce-motion-guarded PTT start haptic in `Sources/Views/Tabs/ChatsTab/MessageInput.swift`
- [x] Fix 3c: Add reduce-motion-guarded PTT end haptic in `Sources/Views/Tabs/ChatsTab/MessageInput.swift`
- [x] Fix 3d: Add reduce-motion-guarded jump-to-latest haptic in `Sources/Views/Tabs/ChatsTab/ChatView.swift`
- [x] Fix 3e: Add reduce-motion-guarded retry haptic in `Sources/Views/Tabs/ChatsTab/MessageBubble.swift`
- [x] Fix 4: Add forced auto-scroll-on-send state in `Sources/Views/Tabs/ChatsTab/ChatView.swift`
- [x] Fix 5: Debounce typing indicator in `Sources/Views/Tabs/ChatsTab/ChatView.swift`
- [x] Fix 6: Add retry loading state in `Sources/Views/Tabs/ChatsTab/MessageBubble.swift`
- [x] Fix 7: Add unread badge animation in `Sources/Views/Tabs/ChatsTab/ChatListCell.swift`

## Verification
- [x] Run keyboard-dismiss grep checks for `MessageInput.swift`
- [x] Run haptics grep checks for `MessageInput.swift`, `ChatView.swift`, and `MessageBubble.swift`
- [x] Run auto-scroll grep check for `ChatView.swift`
- [x] Run typing debounce grep check for `ChatView.swift`
- [x] Run unread badge animation grep check for `ChatListCell.swift`
- [x] Build with `xcodebuild -scheme Blip -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGN_IDENTITY=\"\" CODE_SIGNING_ALLOWED=NO -quiet`
- [x] Run `swift test --package-path Packages/BlipProtocol`
- [x] Run `swift test --package-path Packages/BlipCrypto`
- [x] Run `swift test --package-path Packages/BlipMesh`

## Publish
- [x] Review diff and stage only task files plus `tasks/todo.md`
- [ ] Commit on branch `fix/HEY-1267-chat-ui-polish`
- [ ] Push branch to origin
- [ ] Open a PR in `txc0ld/heyblip`
- [ ] Post in `#blip-dev` that the fix is up
