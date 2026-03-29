import Testing
@testable import BlipProtocol
import Foundation

@Suite("PayloadCompressor")
struct CompressionTests {

    // MARK: - Raw compression round-trip

    @Test("Compress and decompress round-trips")
    func compressDecompress() throws {
        let original = Data("Hello, Blip! This is a test of the compression system. ".utf8)
        let repeated = Data(repeating: 0, count: 5) + original + original + original

        let compressed = PayloadCompressor.compress(repeated)
        #expect(compressed != nil)
        #expect(compressed!.count < repeated.count)

        let decompressed = try PayloadCompressor.decompress(compressed!)
        #expect(decompressed == repeated)
    }

    @Test("Compress empty data returns nil")
    func compressEmpty() {
        #expect(PayloadCompressor.compress(Data()) == nil)
    }

    @Test("Decompress empty data throws")
    func decompressEmpty() {
        #expect(throws: CompressionError.self) {
            try PayloadCompressor.decompress(Data())
        }
    }

    @Test("Decompress invalid data throws")
    func decompressInvalid() {
        let garbage = Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB])
        #expect(throws: (any Error).self) {
            try PayloadCompressor.decompress(garbage)
        }
    }

    // MARK: - Policy: < 100 bytes, no compression

    @Test("Payloads under 100 bytes are not compressed")
    func policySmallPayload() {
        let small = Data(repeating: 0x42, count: 50)
        let result = PayloadCompressor.compressIfNeeded(small)
        #expect(!result.wasCompressed)
        #expect(result.data == small)
    }

    @Test("99 bytes is not compressed")
    func policyAt99() {
        let data = Data(repeating: 0x42, count: 99)
        let result = PayloadCompressor.compressIfNeeded(data)
        #expect(!result.wasCompressed)
    }

    // MARK: - Policy: 100-256 bytes, compress if smaller

    @Test("Compressible data in 100-256 range is compressed")
    func policyCompressibleMidRange() throws {
        let compressible = Data(repeating: 0x00, count: 200)
        let result = PayloadCompressor.compressIfNeeded(compressible)
        #expect(result.wasCompressed)
        #expect(result.data.count < compressible.count)

        let decompressed = try PayloadCompressor.decompress(result.data)
        #expect(decompressed == compressible)
    }

    @Test("Non-compressible data in 100-256 range stays original")
    func policyNonCompressibleMidRange() {
        var random = Data(count: 100)
        for i in 0..<100 { random[i] = UInt8(i) }

        let result = PayloadCompressor.compressIfNeeded(random)
        if !result.wasCompressed {
            #expect(result.data == random)
        }
    }

    // MARK: - Policy: > 256 bytes, always compress

    @Test("Large compressible payload is compressed")
    func policyLargeCompressible() throws {
        let large = Data(repeating: 0x42, count: 500)
        let result = PayloadCompressor.compressIfNeeded(large)
        #expect(result.wasCompressed)

        let decompressed = try PayloadCompressor.decompress(result.data)
        #expect(decompressed == large)
    }

    @Test("Large random data is always compressed (per spec)")
    func policyLargeRandom() {
        var random = Data(count: 300)
        for i in 0..<300 { random[i] = UInt8.random(in: 0...255) }

        let result = PayloadCompressor.compressIfNeeded(random)
        #expect(result.wasCompressed)
    }

    // MARK: - Policy: pre-compressed

    @Test("Pre-compressed data is skipped")
    func policyPreCompressed() {
        let data = Data(repeating: 0x42, count: 500)
        let result = PayloadCompressor.compressIfNeeded(data, isPreCompressed: true)
        #expect(!result.wasCompressed)
        #expect(result.data == data)
    }

    // MARK: - Boundary tests

    @Test("Exactly 100 bytes triggers compression attempt")
    func boundaryAt100() {
        let data = Data(repeating: 0x00, count: 100)
        let result = PayloadCompressor.compressIfNeeded(data)
        #expect(result.wasCompressed)
    }

    @Test("Exactly 256 bytes is in mid-range policy")
    func boundaryAt256() {
        let data = Data(repeating: 0x00, count: 256)
        let result = PayloadCompressor.compressIfNeeded(data)
        #expect(result.wasCompressed)
    }

    @Test("257 bytes is in always-compress policy")
    func boundaryAt257() {
        let data = Data(repeating: 0x00, count: 257)
        let result = PayloadCompressor.compressIfNeeded(data)
        #expect(result.wasCompressed)
    }

    // MARK: - Realistic payload

    @Test("Realistic text message compresses and decompresses")
    func realisticPayload() throws {
        let message = """
        Hey! Are you at the main stage? The band is about to start playing. \
        Meet me near the food trucks by the entrance. I have your jacket. \
        Let me know if you can see the big ferris wheel from where you are.
        """
        let data = Data(message.utf8)
        #expect(data.count > 100)

        let result = PayloadCompressor.compressIfNeeded(data)
        if result.wasCompressed {
            let decompressed = try PayloadCompressor.decompress(result.data)
            #expect(decompressed == data)
        }
    }
}

@Suite("PacketPadding")
struct PaddingTests {

    @Test("Pad to 256")
    func padTo256() {
        let data = Data(repeating: 0x42, count: 100)
        let padded = PacketPadding.pad(data)
        #expect(padded.count == 256)
    }

    @Test("Pad to 512")
    func padTo512() {
        let data = Data(repeating: 0x42, count: 300)
        let padded = PacketPadding.pad(data)
        #expect(padded.count == 512)
    }

    @Test("Pad 600 bytes to 768")
    func pad600() {
        let data = Data(repeating: 0x42, count: 600)
        let padded = PacketPadding.pad(data)
        // 1024 - 600 = 424 > 256, so overflows to (600/256+1)*256 = 768
        #expect(padded.count == 768)
    }

    @Test("Pad 800 bytes to 1024")
    func pad800() {
        let data = Data(repeating: 0x42, count: 800)
        let padded = PacketPadding.pad(data)
        // 1024 - 800 = 224, in [1,256], maps to 1024
        #expect(padded.count == 1024)
    }

    @Test("Pad 1800 bytes to 2048")
    func pad1800() {
        let data = Data(repeating: 0x42, count: 1800)
        let padded = PacketPadding.pad(data)
        // 2048 - 1800 = 248, in [1,256], maps to 2048
        #expect(padded.count == 2048)
    }

    @Test("Pad beyond 2048 rounds to next 256 multiple")
    func padBeyond2048() {
        let data = Data(repeating: 0x42, count: 2100)
        let padded = PacketPadding.pad(data)
        // 2100 rounds up to next 256 multiple: 2304 (= 9 * 256)
        #expect(padded.count == 2304)
    }

    @Test("PKCS#7 padding bytes have correct value")
    func pkcs7Value() {
        let data = Data(repeating: 0x42, count: 250)
        let padded = PacketPadding.pad(data)
        #expect(padded.count == 256)
        let paddingLength = 6
        for i in 250..<256 {
            #expect(padded[i] == UInt8(paddingLength))
        }
    }

    @Test("Exact boundary pads to next available size")
    func exactBoundary() {
        // At exact 256 boundary, pads to 512 (padding = 256 bytes, byte value 0x00)
        let data256 = Data(repeating: 0x42, count: 256)
        let padded256 = PacketPadding.pad(data256)
        #expect(padded256.count == 512)

        // Verify round-trip for exact-boundary case
        let unpadded = PacketPadding.unpad(padded256)
        #expect(unpadded == data256)
    }

    @Test("Unpad recovers original data")
    func unpad() {
        let data = Data(repeating: 0x42, count: 100)
        let padded = PacketPadding.pad(data)
        let unpadded = PacketPadding.unpad(padded)
        #expect(unpadded != nil)
        #expect(unpadded == data)
    }

    @Test("Pad/unpad round-trips for various sizes")
    func roundTrip() {
        for size in [1, 10, 50, 100, 200, 255, 256, 300, 500, 512, 1000, 1024, 2000] {
            let data = Data(repeating: UInt8(size % 256), count: size)
            let padded = PacketPadding.pad(data)
            let unpadded = PacketPadding.unpad(padded)
            #expect(unpadded == data, "Round-trip failed for size \(size)")
        }
    }

    @Test("Unpad empty data returns nil")
    func unpadEmpty() {
        #expect(PacketPadding.unpad(Data()) == nil)
    }

    @Test("Unpad corrupt padding returns nil")
    func unpadCorrupt() {
        var data = Data(repeating: 0x42, count: 250)
        data.append(Data(repeating: 0x06, count: 5))
        data.append(0x05)
        #expect(PacketPadding.unpad(data) == nil)
    }

    @Test("nextBlockSize calculations (tier lookup)")
    func nextBlockSizeCalc() {
        #expect(PacketPadding.nextBlockSize(for: 0) == 256)
        #expect(PacketPadding.nextBlockSize(for: 1) == 256)
        #expect(PacketPadding.nextBlockSize(for: 256) == 256)
        #expect(PacketPadding.nextBlockSize(for: 257) == 512)
        #expect(PacketPadding.nextBlockSize(for: 512) == 512)
        #expect(PacketPadding.nextBlockSize(for: 513) == 1024)
        #expect(PacketPadding.nextBlockSize(for: 1024) == 1024)
        #expect(PacketPadding.nextBlockSize(for: 1025) == 2048)
        #expect(PacketPadding.nextBlockSize(for: 2048) == 2048)
        #expect(PacketPadding.nextBlockSize(for: 2049) == 4096)
    }

    @Test("paddedSize accounts for max 256-byte padding")
    func paddedSizeCalc() {
        // Small data: fits in lowest tier
        #expect(PacketPadding.paddedSize(for: 100) == 256)
        // Exact boundary: bumps to 512 (padding = 256)
        #expect(PacketPadding.paddedSize(for: 256) == 512)
        // Near 512: fits
        #expect(PacketPadding.paddedSize(for: 300) == 512)
        // 800 can reach 1024 with 224 padding
        #expect(PacketPadding.paddedSize(for: 800) == 1024)
        // 1800 can reach 2048 with 248 padding
        #expect(PacketPadding.paddedSize(for: 1800) == 2048)
    }
}
