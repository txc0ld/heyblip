# BDEV-101: Add Missing SwiftData Cascade Delete Rules

## Task

Multiple `@Relationship` declarations are missing `deleteRule: .cascade`, meaning deleting a parent object orphans its children in the database. Also fix the permanent mute bug in GroupMembership.

## Branch

```
git checkout -b fix/bdev-101-cascade-deletes
```

## What to change

### 1. `Sources/Models/Channel.swift`

Add cascade rules to child relationships:

```swift
@Relationship(deleteRule: .cascade, inverse: \Message.channel)
var messages: [Message] = []

@Relationship(deleteRule: .cascade, inverse: \MeetingPoint.channel)
var meetingPoints: [MeetingPoint] = []

@Relationship(deleteRule: .cascade, inverse: \GroupSenderKey.channel)
var senderKeys: [GroupSenderKey] = []
```

### 2. `Sources/Models/Event.swift`

Add cascade to channels:

```swift
@Relationship(deleteRule: .cascade, inverse: \Channel.event)
var channels: [Channel] = []
```

### 3. `Sources/Models/Message.swift`

Add nullify rule for replyTo (don't cascade — deleting a parent message shouldn't delete replies):

```swift
@Relationship(deleteRule: .nullify)
var replyTo: Message?
```

### 4. `Sources/Models/GroupMembership.swift`

Fix the permanent mute bug. When `muted == true` and `mutedUntil == nil`, `isMutedNow` returns true forever.

```swift
var isMutedNow: Bool {
    guard muted else { return false }
    // If no expiry set, mute is indefinite — but should not be permanent
    // Treat nil mutedUntil as "not muted" to prevent accidental permanent mutes
    guard let until = mutedUntil else { return false }
    return Date() < until
}
```

Or if indefinite mutes are intentional, add a separate `isMutedIndefinitely` property and document it clearly.

## Rules

- Build: `xcodebuild -scheme Blip -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -quiet`
- Test: `xcodebuild test -scheme Blip -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -quiet`
- Commit: `fix(models): add cascade delete rules and fix permanent mute bug`
- No force unwraps
- Check that existing inverse relationships are correct before adding delete rules
- SwiftData migration: if the schema version is tracked, bump it

## Verify

- [ ] Build passes
- [ ] Tests pass
- [ ] Deleting a Channel cascades to its messages, meeting points, and sender keys
- [ ] Deleting a Event cascades to its channels
- [ ] Deleting a replied-to message nullifies the replyTo reference (doesn't delete replies)
- [ ] Muting without an expiry date does NOT create a permanent mute
