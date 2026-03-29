import Testing
import Foundation
@testable import BlipCrypto

@Suite("Replay Protection Tests")
struct ReplayProtectionTests {

    // MARK: - In-order acceptance

    @Test("Accepts sequential nonces in order")
    func testSequentialAcceptance() {
        let rp = ReplayProtection()

        for i: UInt64 in 0 ..< 200 {
            #expect(rp.accept(nonce: i), "Nonce \(i) should be accepted")
        }

        #expect(rp.currentHighest == 199)
    }

    @Test("First nonce is always accepted")
    func testFirstNonce() {
        let rp = ReplayProtection()
        #expect(rp.accept(nonce: 1000))
        #expect(rp.currentHighest == 1000)
    }

    // MARK: - Duplicate rejection

    @Test("Rejects duplicate nonces")
    func testDuplicateRejection() {
        let rp = ReplayProtection()

        #expect(rp.accept(nonce: 42))
        #expect(!rp.accept(nonce: 42), "Duplicate nonce should be rejected")
    }

    @Test("Rejects duplicates of the highest nonce")
    func testDuplicateHighest() {
        let rp = ReplayProtection()

        #expect(rp.accept(nonce: 0))
        #expect(rp.accept(nonce: 1))
        #expect(rp.accept(nonce: 2))
        #expect(!rp.accept(nonce: 2), "Duplicate of highest should be rejected")
        #expect(!rp.accept(nonce: 1), "Duplicate of earlier should be rejected")
        #expect(!rp.accept(nonce: 0), "Duplicate of earliest should be rejected")
    }

    // MARK: - Out-of-order acceptance within window

    @Test("Accepts out-of-order nonces within window")
    func testOutOfOrderWithinWindow() {
        let rp = ReplayProtection()

        // Establish highest at 100
        #expect(rp.accept(nonce: 100))

        // Accept nonces within the 128-bit window (100 - 127 = offset up to 127 is valid)
        #expect(rp.accept(nonce: 99))   // offset 1
        #expect(rp.accept(nonce: 50))   // offset 50
        #expect(rp.accept(nonce: 1))    // offset 99
        #expect(rp.accept(nonce: 0))    // offset 100 (still within 128 window)

        // But duplicates within window are still rejected
        #expect(!rp.accept(nonce: 50))
        #expect(!rp.accept(nonce: 99))
    }

    @Test("Accepts nonce at maximum window offset")
    func testMaximumWindowOffset() {
        let rp = ReplayProtection()

        // Set highest to 127 (so nonce 0 is at offset 127, which is the last valid position)
        #expect(rp.accept(nonce: 127))
        #expect(rp.accept(nonce: 0), "Nonce at exact window boundary (offset 127) should be accepted")
    }

    // MARK: - Nonces too old (outside window)

    @Test("Rejects nonces older than window")
    func testOldNonceRejection() {
        let rp = ReplayProtection()

        // Set highest to 200
        #expect(rp.accept(nonce: 200))

        // Nonce 200 - 128 = 72 is the oldest valid nonce
        #expect(rp.accept(nonce: 73))  // offset 127 -- at the boundary
        #expect(!rp.accept(nonce: 72), "Nonce at offset 128 should be rejected (outside window)")
        #expect(!rp.accept(nonce: 0), "Very old nonce should be rejected")
    }

    // MARK: - Window sliding

    @Test("Window slides forward correctly on new highest nonce")
    func testWindowSliding() {
        let rp = ReplayProtection()

        // Accept nonces 0-9
        for i: UInt64 in 0 ..< 10 {
            #expect(rp.accept(nonce: i))
        }

        // Jump to 200 -- window should slide, old nonces fall outside
        #expect(rp.accept(nonce: 200))
        #expect(rp.currentHighest == 200)

        // Nonces 0-72 are now outside the 128-bit window (200 - 128 = 72)
        #expect(!rp.accept(nonce: 0))
        #expect(!rp.accept(nonce: 72))

        // But 73-199 should be accepted (if not already seen)
        // 73 is at offset 127 from 200
        #expect(rp.accept(nonce: 73))
        #expect(rp.accept(nonce: 150))
        #expect(rp.accept(nonce: 199))
    }

    @Test("Large jump clears entire window")
    func testLargeJump() {
        let rp = ReplayProtection()

        // Accept some nonces
        for i: UInt64 in 0 ..< 50 {
            #expect(rp.accept(nonce: i))
        }

        // Jump far ahead (> 128)
        #expect(rp.accept(nonce: 1000))
        #expect(rp.currentHighest == 1000)

        // All old nonces should be outside the window
        #expect(!rp.accept(nonce: 49))
        #expect(!rp.accept(nonce: 0))

        // But nonces within the new window should work
        #expect(rp.accept(nonce: 999))
        #expect(rp.accept(nonce: 873))  // offset 127
        #expect(!rp.accept(nonce: 872)) // offset 128, outside
    }

    // MARK: - Bitmap edge cases

    @Test("Bitmap boundary at 64 bits (crossing low/high boundary)")
    func testBitmapBoundary() {
        let rp = ReplayProtection()

        #expect(rp.accept(nonce: 100))

        // Nonces at various offsets around the 64-bit boundary
        #expect(rp.accept(nonce: 37))  // offset 63 (last bit in low)
        #expect(rp.accept(nonce: 36))  // offset 64 (first bit in high)
        #expect(rp.accept(nonce: 35))  // offset 65
        #expect(rp.accept(nonce: 1))   // offset 99

        // Verify duplicates still caught
        #expect(!rp.accept(nonce: 37))
        #expect(!rp.accept(nonce: 36))
        #expect(!rp.accept(nonce: 35))
    }

    // MARK: - hasSeen query

    @Test("hasSeen reports correctly without modifying state")
    func testHasSeen() {
        let rp = ReplayProtection()

        #expect(!rp.hasSeen(nonce: 0))  // Nothing seen yet

        #expect(rp.accept(nonce: 5))
        #expect(rp.accept(nonce: 10))

        #expect(rp.hasSeen(nonce: 5))
        #expect(rp.hasSeen(nonce: 10))
        #expect(!rp.hasSeen(nonce: 7))   // Not seen
        #expect(!rp.hasSeen(nonce: 100)) // Future, not seen
    }

    // MARK: - Reset

    @Test("Reset clears all state")
    func testReset() {
        let rp = ReplayProtection()

        #expect(rp.accept(nonce: 100))
        #expect(rp.accept(nonce: 50))

        rp.reset()

        // After reset, the same nonces should be accepted again
        #expect(rp.accept(nonce: 100))
        #expect(rp.accept(nonce: 50))
        #expect(rp.currentHighest == 100)
    }

    // MARK: - Stress test

    @Test("Handles many sequential nonces without issues")
    func testManySequentialNonces() {
        let rp = ReplayProtection()

        // Accept 10,000 sequential nonces
        for i: UInt64 in 0 ..< 10_000 {
            #expect(rp.accept(nonce: i), "Nonce \(i) should be accepted")
        }

        #expect(rp.currentHighest == 9999)

        // Replay any of the recent ones should fail
        for i: UInt64 in 9_900 ..< 10_000 {
            #expect(!rp.accept(nonce: i), "Replay of \(i) should be rejected")
        }

        // Very old nonces should be rejected
        #expect(!rp.accept(nonce: 0))
        #expect(!rp.accept(nonce: 9871))  // offset 128
    }

    @Test("Handles random-order arrival within window")
    func testRandomOrderArrival() {
        let rp = ReplayProtection()

        // Establish highest
        #expect(rp.accept(nonce: 200))

        // Accept nonces in a shuffled order within the window
        let nonces: [UInt64] = [150, 180, 110, 199, 130, 170, 90, 100, 160, 140, 120, 73]
        for n in nonces {
            #expect(rp.accept(nonce: n), "Nonce \(n) should be accepted on first try")
        }

        // All should now be seen
        for n in nonces {
            #expect(!rp.accept(nonce: n), "Nonce \(n) should be rejected on second try")
        }
    }
}
