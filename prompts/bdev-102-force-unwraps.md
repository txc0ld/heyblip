# BDEV-102: Remove Force Unwraps and Fix Missing Nil Checks in Views

## Task

Several Views access optionals unsafely or fall back to sample data silently. Fix all force unwraps, add proper nil checks, and remove silent fallbacks.

## Branch

```
git checkout -b fix/bdev-102-force-unwraps
```

## What to change

### 1. `Sources/Services/AudioService.swift` — Force unwraps on ASCII encoding

Find the WAV header construction (~lines 552-567). Replace force unwraps with safe alternatives:

```swift
// BEFORE:
wav.append("RIFF".data(using: .ascii)!)

// AFTER:
guard let riff = "RIFF".data(using: .ascii),
      let wave = "WAVE".data(using: .ascii),
      let fmt = "fmt ".data(using: .ascii),
      let dataTag = "data".data(using: .ascii) else {
    throw AudioError.wavEncodingFailed
}
wav.append(riff)
wav.append(wave)
wav.append(fmt)
wav.append(dataTag)
```

### 2. `Sources/Views/ChatsTab/ChatView.swift` — Sample data fallback

Find where chatViewModel is checked (~line 243). Replace sample data fallback with an assertion or empty state:

```swift
// BEFORE:
guard let vm = chatViewModel else { return ChatMessage.sampleMessages }

// AFTER:
guard let vm = chatViewModel else {
    DebugLogger.emit("UI", "ChatView: chatViewModel is nil — showing empty state", isError: true)
    return []
}
```

### 3. `Sources/Views/ChatsTab/ChatView.swift` — profileViewModel nil check

Find coordinator access (~line 289):

```swift
// BEFORE:
coordinator.profileViewModel?.loadProfile()

// AFTER:
if let profileVM = coordinator.profileViewModel {
    Task { try? await profileVM.loadProfile() }
} else {
    DebugLogger.emit("UI", "ChatView: profileViewModel is nil", isError: true)
}
```

### 4. `Sources/Views/NearbyTab/NearbyView.swift` — container nil check

Find the task closure (~line 85):

```swift
// Ensure container is safely unwrapped before use
guard let container = modelContext.container else {
    DebugLogger.emit("UI", "NearbyView: modelContext.container is nil", isError: true)
    return
}
localMeshViewModel = MeshViewModel(modelContainer: container)
```

Note: `modelContext.container` might not actually be optional in SwiftData — check the type. If it's non-optional, no change needed.

### 5. `Sources/Views/EventsTab/EventView.swift` — coordinate validation

Find where CLLocationCoordinate2D is created (~line 99):

```swift
// Add bounds check before creating coordinate
guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
    DebugLogger.emit("UI", "EventView: invalid coordinates (\(latitude), \(longitude))", isError: true)
    return
}
let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
```

### 6. `Sources/Views/ChatsTab/MessageBubble.swift` — image decode nil check

Find UIImage creation (~line 158):

```swift
// BEFORE:
if let imageData = message.imageData {
    Image(uiImage: UIImage(data: imageData))

// AFTER:
if let imageData = message.imageData,
   let uiImage = UIImage(data: imageData) {
    Image(uiImage: uiImage)
} else if message.imageData != nil {
    // Image data exists but couldn't be decoded
    Image(systemName: "photo.badge.exclamationmark")
        .foregroundColor(.secondary)
}
```

## Rules

- Build: `xcodebuild -scheme Blip -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -quiet`
- Test: `xcodebuild test -scheme Blip -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -quiet`
- Commit: `fix(views): remove force unwraps and add nil safety checks`
- No force unwraps anywhere
- Use `DebugLogger.emit()` for logging from non-MainActor contexts
- Don't change any UI layout or design — only fix safety issues

## Verify

- [ ] Build passes
- [ ] Tests pass
- [ ] Zero force unwraps (`!`) in modified files
- [ ] No silent sample data fallbacks in production paths
- [ ] Grep the entire Sources/ directory for remaining `!` on optionals
