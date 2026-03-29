import Testing
@testable import BlipProtocol
import Foundation
import CryptoKit

@Suite("BloomFilterTier")
struct BloomFilterTierTests {

    @Test("Basic insert and query")
    func basicInsertQuery() {
        var filter = BloomFilterTier(sizeInBytes: 4096, expectedElements: 500)

        let id1 = Data("packet_001".utf8)
        let id2 = Data("packet_002".utf8)
        let id3 = Data("packet_003".utf8)

        filter.insert(id1)
        filter.insert(id2)

        #expect(filter.mightContain(id1))
        #expect(filter.mightContain(id2))
        #expect(!filter.mightContain(id3))
    }

    @Test("Inserted count tracks correctly")
    func insertedCount() {
        var filter = BloomFilterTier(sizeInBytes: 1024, expectedElements: 100)
        #expect(filter.insertedCount == 0)

        filter.insert(Data("a".utf8))
        #expect(filter.insertedCount == 1)

        filter.insert(Data("b".utf8))
        #expect(filter.insertedCount == 2)
    }

    @Test("Reset clears filter")
    func reset() {
        var filter = BloomFilterTier(sizeInBytes: 1024, expectedElements: 100)

        let id = Data("test".utf8)
        filter.insert(id)
        #expect(filter.mightContain(id))

        filter.reset()
        #expect(filter.insertedCount == 0)
        #expect(!filter.mightContain(id))
    }

    @Test("False positive rate below 1% with 500 elements in 4KB")
    func falsePositiveRate() {
        var filter = BloomFilterTier(sizeInBytes: 4096, expectedElements: 500)
        var inserted = Set<Data>()

        for i in 0..<500 {
            let id = withUnsafeBytes(of: UInt64(i).bigEndian) { Data($0) }
            filter.insert(id)
            inserted.insert(id)
        }

        for id in inserted {
            #expect(filter.mightContain(id))
        }

        var falsePositives = 0
        for i in 1000..<11000 {
            let id = withUnsafeBytes(of: UInt64(i).bigEndian) { Data($0) }
            if !inserted.contains(id) && filter.mightContain(id) {
                falsePositives += 1
            }
        }

        let fpr = Double(falsePositives) / 10000.0
        #expect(fpr < 0.01, "False positive rate \(fpr) exceeds 1%")
    }

    @Test("Estimated false positive rate is reasonable")
    func estimatedFPR() {
        var filter = BloomFilterTier(sizeInBytes: 4096, expectedElements: 500)
        #expect(filter.estimatedFalsePositiveRate < 0.001)

        for i in 0..<500 {
            filter.insert(withUnsafeBytes(of: UInt64(i)) { Data($0) })
        }

        let estimate = filter.estimatedFalsePositiveRate
        #expect(estimate > 0)
        #expect(estimate < 0.01)
    }

    @Test("Double-hashing provides low FPR")
    func doubleHashing() {
        var filter = BloomFilterTier(sizeInBytes: 4096, expectedElements: 500)

        for i in 0..<500 {
            let data = SHA256.hash(data: withUnsafeBytes(of: UInt64(i)) { Data($0) })
            filter.insert(Data(data))
        }

        var falsePositives = 0
        let testCount = 5000
        for i in 10000..<10000 + testCount {
            let data = SHA256.hash(data: withUnsafeBytes(of: UInt64(i)) { Data($0) })
            if filter.mightContain(Data(data)) {
                falsePositives += 1
            }
        }

        let fpr = Double(falsePositives) / Double(testCount)
        #expect(fpr < 0.005, "Double-hashing FPR \(fpr) is too high")
    }
}

@Suite("MultiTierBloomFilter")
struct MultiTierBloomFilterTests {

    @Test("Insert and contains work")
    func insertContains() {
        let filter = MultiTierBloomFilter()

        let id1 = Data("msg_alpha".utf8)
        let id2 = Data("msg_beta".utf8)
        let id3 = Data("msg_gamma".utf8)

        filter.insert(id1)
        filter.insert(id2)

        #expect(filter.contains(id1))
        #expect(filter.contains(id2))
        #expect(!filter.contains(id3))
    }

    @Test("Reset clears all tiers")
    func reset() {
        let filter = MultiTierBloomFilter()
        let id = Data("reset_test".utf8)
        filter.insert(id)
        #expect(filter.contains(id))

        filter.reset()
        #expect(!filter.contains(id))
    }

    @Test("Tier counts track hot inserts")
    func tierCounts() {
        let filter = MultiTierBloomFilter()
        let counts0 = filter.tierCounts
        #expect(counts0.hot == 0)
        #expect(counts0.warm == 0)
        #expect(counts0.cold == 0)

        for i in 0..<10 {
            filter.insert(withUnsafeBytes(of: UInt64(i)) { Data($0) })
        }

        let counts1 = filter.tierCounts
        #expect(counts1.hot == 10)
    }

    @Test("Tier sizes match spec Section 8.7")
    func tierSizes() {
        #expect(MultiTierBloomFilter.hotSizeBytes == 4096)
        #expect(MultiTierBloomFilter.warmSizeBytes == 16384)
        #expect(MultiTierBloomFilter.coldSizeBytes == 65536)
    }

    @Test("Tier window durations match spec")
    func tierWindows() {
        #expect(MultiTierBloomFilter.hotWindowSec == 60.0)
        #expect(MultiTierBloomFilter.warmWindowSec == 600.0)
        #expect(MultiTierBloomFilter.coldWindowSec == 7200.0)
    }

    @Test("1000 inserts all found")
    func manyInserts() {
        let filter = MultiTierBloomFilter()
        var allIDs = [Data]()
        for i in 0..<1000 {
            let id = withUnsafeBytes(of: UInt64(i).bigEndian) { Data($0) }
            filter.insert(id)
            allIDs.append(id)
        }

        for id in allIDs {
            #expect(filter.contains(id))
        }
    }
}

@Suite("GCSFilter")
struct GCSFilterTests {

    @Test("Encode/decode round-trip with 50 elements")
    func encodeDecodeRoundTrip() {
        var messageIDs = Set<Data>()
        for i in 0..<50 {
            let id = withUnsafeBytes(of: UInt64(i).bigEndian) { Data($0) }
            messageIDs.insert(id)
        }

        let encoded = GCSFilter.encode(messageIDs)
        #expect(encoded != nil)
        #expect(encoded!.count <= GCSFilter.maxEncodedSize)

        let decoded = GCSFilter.decode(encoded!)
        #expect(decoded != nil)
        #expect(decoded?.count == 50)
    }

    @Test("Empty set encodes and decodes")
    func emptySet() {
        let encoded = GCSFilter.encode(Set<Data>())
        #expect(encoded != nil)
        #expect(encoded?.count == 0)

        let decoded = GCSFilter.decode(Data())
        #expect(decoded != nil)
        #expect(decoded?.count == 0)
    }

    @Test("Membership check finds inserted IDs")
    func membershipCheck() {
        var messageIDs = Set<Data>()
        for i in 0..<20 {
            let id = Data("msg_\(i)".utf8)
            messageIDs.insert(id)
        }

        guard let encoded = GCSFilter.encode(messageIDs) else {
            Issue.record("GCS encoding failed")
            return
        }

        for id in messageIDs {
            #expect(GCSFilter.mightContain(id, in: encoded))
        }
    }

    @Test("False positive rate is reasonable")
    func falsePositiveRate() {
        var messageIDs = Set<Data>()
        for i in 0..<100 {
            let id = withUnsafeBytes(of: UInt64(i).bigEndian) { Data($0) }
            messageIDs.insert(id)
        }

        guard let encoded = GCSFilter.encode(messageIDs) else {
            Issue.record("GCS encoding failed")
            return
        }

        var falsePositives = 0
        for i in 10000..<11000 {
            let id = withUnsafeBytes(of: UInt64(i).bigEndian) { Data($0) }
            if GCSFilter.mightContain(id, in: encoded) {
                falsePositives += 1
            }
        }

        let fpr = Double(falsePositives) / 1000.0
        #expect(fpr < 0.05, "GCS FPR \(fpr) is too high")
    }

    @Test("Max encoded size is 400 bytes")
    func maxEncodedSize() {
        #expect(GCSFilter.maxEncodedSize == 400)
    }

    @Test("Golomb parameters match spec")
    func golombParameters() {
        #expect(GCSFilter.golombM == 128)
        #expect(GCSFilter.riceParameter == 7)
    }

    @Test("findMissing identifies IDs not in remote filter")
    func findMissing() {
        var remoteIDs = Set<Data>()
        for i in 0..<50 {
            let id = withUnsafeBytes(of: UInt64(i).bigEndian) { Data($0) }
            remoteIDs.insert(id)
        }

        guard let remoteFilter = GCSFilter.encode(remoteIDs) else {
            Issue.record("GCS encoding failed")
            return
        }

        var localIDs = Set<Data>()
        for i in 40..<60 {
            let id = withUnsafeBytes(of: UInt64(i).bigEndian) { Data($0) }
            localIDs.insert(id)
        }

        let missing = GCSFilter.findMissing(localIDs: localIDs, remoteFilter: remoteFilter)

        for i in 50..<60 {
            let id = withUnsafeBytes(of: UInt64(i).bigEndian) { Data($0) }
            #expect(missing.contains(id), "ID \(i) should be reported as missing")
        }
    }

    @Test("Single element encodes and decodes")
    func singleElement() {
        let id = Data("only_one".utf8)
        var ids = Set<Data>()
        ids.insert(id)

        let encoded = GCSFilter.encode(ids)
        #expect(encoded != nil)
        #expect(GCSFilter.mightContain(id, in: encoded!))

        let decoded = GCSFilter.decode(encoded!)
        #expect(decoded?.count == 1)
    }
}
