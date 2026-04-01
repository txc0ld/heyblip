import XCTest
@testable import BlipCrypto
import BlipProtocol

final class SignerMalformedPacketTests: XCTestCase {

    func testRejectsEmptyPacket() {
        XCTAssertThrowsError(try Signer.extractSignableData(from: Data())) { error in
            XCTAssertEqual(error as? SignerError, .packetTooShort)
        }
    }

    func testRejectsThreeBytePacket() {
        let tiny = Data([0x01, 0x02, 0x03])
        XCTAssertThrowsError(try Signer.extractSignableData(from: tiny)) { error in
            XCTAssertEqual(error as? SignerError, .packetTooShort)
        }
    }

    func testRejectsFifteenBytePacket() {
        let undersize = Data(repeating: 0x00, count: 15)
        XCTAssertThrowsError(try Signer.extractSignableData(from: undersize)) { error in
            XCTAssertEqual(error as? SignerError, .packetTooShort)
        }
    }

    func testAcceptsMinimumValidPacket() {
        let validHeader = Data(repeating: 0x00, count: Packet.headerSize)
        XCTAssertNoThrow(try Signer.extractSignableData(from: validHeader))
    }

    func testAcceptsLargerPacket() {
        let large = Data(repeating: 0xAB, count: Packet.headerSize + 64)
        XCTAssertNoThrow(try Signer.extractSignableData(from: large))
    }
}
