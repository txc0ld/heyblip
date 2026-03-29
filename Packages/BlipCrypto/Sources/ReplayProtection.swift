import Foundation

// MARK: - ReplayProtection

/// Sliding-window nonce tracker for replay protection.
///
/// Uses a 64-bit highest-received counter and a 128-bit bitmap to track
/// recently seen nonces within a window. Nonces that fall behind the window
/// or have already been seen are rejected.
///
/// Per spec Section 7.1: "Replay protection: sliding window nonce
/// (64-bit counter + 128-bit window)."
///
/// The window covers nonces from `(highestNonce - windowSize + 1)` to `highestNonce`.
/// Bit `i` in the bitmap represents whether nonce `(highestNonce - i)` has been seen.
public final class ReplayProtection: @unchecked Sendable {

    // MARK: - Constants

    /// Size of the sliding window in bits.
    public static let windowSize: UInt64 = 128

    // MARK: - State

    /// The highest nonce value that has been accepted.
    private var highestNonce: UInt64 = 0

    /// 128-bit bitmap stored as two UInt64 values.
    /// bitmapLow holds bits [0..63], bitmapHigh holds bits [64..127].
    /// Bit 0 corresponds to highestNonce, bit 1 to highestNonce-1, etc.
    private var bitmapLow: UInt64 = 0
    private var bitmapHigh: UInt64 = 0

    /// Whether any nonce has been accepted yet.
    private var initialized: Bool = false

    /// Lock for thread safety.
    private let lock = NSLock()

    // MARK: - Init

    public init() {}

    // MARK: - Accept

    /// Check and record a nonce value.
    ///
    /// Returns `true` if the nonce is valid (not a replay, not too old) and has
    /// been recorded. Returns `false` if the nonce should be rejected.
    ///
    /// - Parameter nonce: The 64-bit nonce from the incoming message.
    /// - Returns: `true` if the nonce is accepted; `false` if it's a replay or too old.
    public func accept(nonce: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if !initialized {
            highestNonce = nonce
            initialized = true
            bitmapLow = 1  // Mark bit 0 (the highestNonce itself)
            bitmapHigh = 0
            return true
        }

        if nonce > highestNonce {
            let shift = nonce - highestNonce
            if shift >= Self.windowSize {
                bitmapLow = 0
                bitmapHigh = 0
            } else {
                shiftBitmapLeft(by: shift)
            }
            highestNonce = nonce
            bitmapLow |= 1  // Set bit 0 for the new highest
            return true
        }

        // nonce <= highestNonce
        let offset = highestNonce - nonce

        if offset >= Self.windowSize {
            return false
        }

        if getBit(at: offset) {
            return false
        }

        setBit(at: offset)
        return true
    }

    // MARK: - Query

    /// Check if a nonce has been seen without recording it.
    public func hasSeen(nonce: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard initialized else { return false }
        if nonce > highestNonce { return false }

        let offset = highestNonce - nonce
        if offset >= Self.windowSize { return false }

        return getBit(at: offset)
    }

    /// The current highest accepted nonce.
    public var currentHighest: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return highestNonce
    }

    /// Reset all state.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        highestNonce = 0
        bitmapLow = 0
        bitmapHigh = 0
        initialized = false
    }

    // MARK: - Bitmap operations

    /// Get the bit at the given offset in the 128-bit bitmap.
    private func getBit(at offset: UInt64) -> Bool {
        if offset < 64 {
            return (bitmapLow >> offset) & 1 == 1
        } else {
            return (bitmapHigh >> (offset - 64)) & 1 == 1
        }
    }

    /// Set the bit at the given offset in the 128-bit bitmap.
    private func setBit(at offset: UInt64) {
        if offset < 64 {
            bitmapLow |= (1 << offset)
        } else {
            bitmapHigh |= (1 << (offset - 64))
        }
    }

    /// Shift the 128-bit bitmap LEFT by `count` positions.
    ///
    /// When the highest nonce advances by `count`, all previously-recorded nonces
    /// move to higher bit offsets (further from the new highest). This is a left
    /// shift of the 128-bit bitmap, which clears the low bits for the new nonce.
    /// Bits that shift past position 127 fall off (those nonces are now outside
    /// the window).
    ///
    /// Conceptually the 128-bit number is `[bitmapHigh:bitmapLow]` where bitmapLow
    /// holds bits [0..63] and bitmapHigh holds bits [64..127].
    private func shiftBitmapLeft(by count: UInt64) {
        guard count > 0 else { return }

        if count >= 128 {
            bitmapLow = 0
            bitmapHigh = 0
            return
        }

        if count >= 64 {
            // All bits from bitmapLow shift into (or past) bitmapHigh.
            let extra = count - 64
            if extra == 0 {
                bitmapHigh = bitmapLow
            } else if extra < 64 {
                bitmapHigh = bitmapLow << extra
            } else {
                bitmapHigh = 0
            }
            bitmapLow = 0
            return
        }

        // count in 1..63
        // Bits at the top of bitmapLow carry into bitmapHigh.
        // new_high = (old_high << count) | (old_low >> (64 - count))
        // new_low  = old_low << count
        let newHigh = (bitmapHigh << count) | (bitmapLow >> (64 - count))
        let newLow = bitmapLow << count
        bitmapHigh = newHigh
        bitmapLow = newLow
    }
}
