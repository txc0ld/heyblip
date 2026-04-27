import XCTest
@testable import Blip

/// Tests for `CrashReportingService.fingerprintForLogMessage`, the helper
/// added under BDEV-417 to split mixed-fingerprint Sentry issues by their
/// `[TAG]` prefix.
///
/// These tests are pure-function — they don't initialise the Sentry SDK
/// or any other runtime state, so they're safe to run in any harness.
final class CrashReportingFingerprintTests: XCTestCase {

    // MARK: - Tag extraction

    func test_simpleAuthTag_groupsByTagAndNormalisedHead() {
        let result = CrashReportingService.fingerprintForLogMessage(
            "[AUTH] Challenge request failed HTTP 429"
        )
        XCTAssertEqual(result, ["log", "AUTH", "Challenge request failed HTTP N"])
    }

    func test_noiseHandshakeFailure_groupsSeparatelyFromAuth() {
        let auth = CrashReportingService.fingerprintForLogMessage(
            "[AUTH] Key upload failed HTTP 429"
        )
        let noise = CrashReportingService.fingerprintForLogMessage(
            "[NOISE] Handshake msg2 messageDecryptionFailed"
        )
        XCTAssertNotNil(auth)
        XCTAssertNotNil(noise)
        XCTAssertNotEqual(auth, noise, "different [TAG] prefixes must produce different fingerprints")
        XCTAssertEqual(auth?[1], "AUTH")
        XCTAssertEqual(noise?[1], "NOISE")
    }

    // MARK: - Numeric normalisation

    func test_differentStatusCodes_groupTogether() {
        let h429 = CrashReportingService.fingerprintForLogMessage(
            "[AUTH] Challenge request failed HTTP 429"
        )
        let h500 = CrashReportingService.fingerprintForLogMessage(
            "[AUTH] Challenge request failed HTTP 500"
        )
        XCTAssertEqual(h429, h500, "different HTTP status codes must collapse onto one fingerprint")
    }

    func test_differentByteLengths_groupTogether() {
        let len12 = CrashReportingService.fingerprintForLogMessage(
            "[NOISE] Handshake msg2 failed msg2.len=12"
        )
        let len48 = CrashReportingService.fingerprintForLogMessage(
            "[NOISE] Handshake msg2 failed msg2.len=48"
        )
        XCTAssertEqual(len12, len48)
    }

    // MARK: - Long messages truncate to a stable head

    func test_longMessageBody_truncatesAtSixtyChars() {
        let short = CrashReportingService.fingerprintForLogMessage(
            "[NOISE] Handshake msg2 failed once for peer ABCD with no detail"
        )
        let withTail = CrashReportingService.fingerprintForLogMessage(
            "[NOISE] Handshake msg2 failed once for peer ABCD with no detail and a long trailing breadcrumb that should not affect grouping"
        )
        XCTAssertEqual(short, withTail, "trailing variable detail past ~60 chars must not change the fingerprint")
    }

    // MARK: - Edge cases — return nil so Sentry default grouping applies

    func test_messageWithoutTagPrefix_returnsNil() {
        let result = CrashReportingService.fingerprintForLogMessage(
            "Crash without a tag — this should keep Sentry's default fingerprint"
        )
        XCTAssertNil(result)
    }

    func test_emptyTag_returnsNil() {
        XCTAssertNil(CrashReportingService.fingerprintForLogMessage("[] empty"))
    }

    func test_tagWithSpaces_returnsNil() {
        // "[NOT A TAG]" should NOT be parsed as a tag — guard against false-positive
        // tag matches on system messages that happen to start with a bracket.
        XCTAssertNil(CrashReportingService.fingerprintForLogMessage(
            "[NOT A TAG] something"
        ))
    }

    func test_messageWithBracketButNoClose_returnsNil() {
        XCTAssertNil(CrashReportingService.fingerprintForLogMessage(
            "[unterminated tag rest of message"
        ))
    }
}
