import Foundation

/// Centralised "which voice note is playing right now?" registry.
///
/// Each `VoiceNotePlayer` owns its own `AudioService` instance (it has to —
/// playback state is per-bubble), but only ONE bubble may actually drive the
/// shared `AVAudioSession` at a time. Without coordination, scrolling up and
/// tapping an older note simply layers it on top of the currently playing note,
/// producing garbled overlapping audio (Finding audio-#11).
///
/// The coordinator solves this with a single observable token. When a player
/// starts, it claims the token. Every other player observes the change and
/// stops itself if its token no longer matches. The coordinator never touches
/// `AudioService` directly — it just publishes intent and lets each player
/// react to it.
@MainActor
@Observable
final class VoiceNotePlaybackCoordinator {

    /// Process-wide singleton. Voice note bubbles are short-lived view structs
    /// so we can't inject this through `Environment` without ceremony, but the
    /// coordinator carries no per-user state — only "who's playing right now"
    /// — so a singleton is fine.
    static let shared = VoiceNotePlaybackCoordinator()

    /// Identifier of the player currently driving audio output, or `nil` if
    /// nothing is playing. Players observe this and stop themselves when the
    /// value no longer matches their own token.
    private(set) var activePlayerToken: UUID?

    private init() {}

    /// Claim playback. Returns the new token; existing players observing the
    /// change should compare against their stored token and stop on mismatch.
    @discardableResult
    func claim() -> UUID {
        let token = UUID()
        activePlayerToken = token
        return token
    }

    /// Release playback if `token` is still the active one. Players call this
    /// when their playback finishes naturally — releasing someone else's claim
    /// would silently abort an unrelated note.
    func release(_ token: UUID) {
        guard activePlayerToken == token else { return }
        activePlayerToken = nil
    }

    /// Force-clear the active player. Use when audio session gets seized
    /// externally (interruption, route change) and we want all UI to reset.
    func clear() {
        activePlayerToken = nil
    }
}
