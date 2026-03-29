import Testing
@testable import BlipProtocol
import Foundation

@Suite("FragmentSplitter")
struct FragmentSplitterTests {

    @Test("Small payload does not need fragmentation")
    func noFragmentationNeeded() {
        let payload = Data(repeating: 0x42, count: 100)
        #expect(!FragmentSplitter.needsFragmentation(payload))

        let fragments = FragmentSplitter.split(payload)
        #expect(fragments.count == 1)
        #expect(fragments[0].index == 0)
        #expect(fragments[0].total == 1)
        #expect(fragments[0].data == payload)
    }

    @Test("Max fragment payload is 408 (416 - 8 header)")
    func maxFragmentPayload() {
        #expect(FragmentSplitter.maxFragmentPayload == 408)
    }

    @Test("Fragmentation at threshold boundary")
    func thresholdBoundary() {
        let maxChunk = FragmentSplitter.maxFragmentPayload

        let atThreshold = Data(repeating: 0x42, count: maxChunk)
        #expect(!FragmentSplitter.needsFragmentation(atThreshold))

        let overThreshold = Data(repeating: 0x42, count: maxChunk + 1)
        #expect(FragmentSplitter.needsFragmentation(overThreshold))
    }

    @Test("Payload splits into two fragments correctly")
    func splitIntoTwo() {
        let maxChunk = FragmentSplitter.maxFragmentPayload
        let payload = Data(repeating: 0xAA, count: maxChunk + 10)
        let fragments = FragmentSplitter.split(payload)

        #expect(fragments.count == 2)
        #expect(fragments[0].fragmentID == fragments[1].fragmentID)
        #expect(fragments[0].index == 0)
        #expect(fragments[1].index == 1)
        #expect(fragments[0].total == 2)
        #expect(fragments[1].total == 2)
        #expect(fragments[0].data.count == maxChunk)
        #expect(fragments[1].data.count == 10)
    }

    @Test("Large payload splits correctly and reassembles")
    func splitLargePayload() {
        let payload = Data(repeating: 0xBB, count: 2048)
        let fragments = FragmentSplitter.split(payload)
        let expected = FragmentSplitter.fragmentCount(for: 2048)
        #expect(fragments.count == expected)

        var reassembled = Data()
        for frag in fragments {
            #expect(frag.total == UInt16(expected))
            reassembled.append(frag.data)
        }
        #expect(reassembled == payload)
    }

    @Test("Fragment count calculation")
    func fragmentCount() {
        let maxChunk = FragmentSplitter.maxFragmentPayload
        #expect(FragmentSplitter.fragmentCount(for: 0) == 0)
        #expect(FragmentSplitter.fragmentCount(for: 1) == 1)
        #expect(FragmentSplitter.fragmentCount(for: maxChunk) == 1)
        #expect(FragmentSplitter.fragmentCount(for: maxChunk + 1) == 2)
        #expect(FragmentSplitter.fragmentCount(for: maxChunk * 2) == 2)
        #expect(FragmentSplitter.fragmentCount(for: maxChunk * 2 + 1) == 3)
    }

    @Test("Fragment header size is 8 bytes")
    func headerSize() {
        #expect(FragmentHeader.size == 8)
    }

    @Test("Fragment max TTL is 5")
    func maxTTL() {
        #expect(FragmentSplitter.maxFragmentTTL == 5)
    }
}

@Suite("Fragment serialization")
struct FragmentSerializationTests {

    @Test("Serialize and parse round-trip")
    func serializeParse() {
        let fragment = Fragment(
            fragmentID: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            index: 3, total: 10,
            data: Data("fragment data".utf8)
        )

        let serialized = fragment.serialize()
        #expect(serialized.count == 8 + fragment.data.count)

        let parsed = Fragment.parse(serialized)
        #expect(parsed != nil)
        #expect(parsed?.fragmentID == fragment.fragmentID)
        #expect(parsed?.index == 3)
        #expect(parsed?.total == 10)
        #expect(parsed?.data == fragment.data)
    }

    @Test("Parse too-short data returns nil")
    func parseTooShort() {
        let data = Data([0x01, 0x02, 0x03])
        #expect(Fragment.parse(data) == nil)
    }

    @Test("Serialized header format is correct")
    func headerFormat() {
        let fragment = Fragment(
            fragmentID: Data([0x01, 0x02, 0x03, 0x04]),
            index: 0x0005, total: 0x000A,
            data: Data()
        )
        let serialized = fragment.serialize()

        #expect(serialized[0] == 0x01)
        #expect(serialized[1] == 0x02)
        #expect(serialized[2] == 0x03)
        #expect(serialized[3] == 0x04)
        #expect(serialized[4] == 0x00)  // index high
        #expect(serialized[5] == 0x05)  // index low
        #expect(serialized[6] == 0x00)  // total high
        #expect(serialized[7] == 0x0A)  // total low
    }
}

@Suite("FragmentAssembler")
struct FragmentAssemblerTests {

    @Test("In-order assembly completes correctly")
    func inOrderAssembly() throws {
        let payload = Data(repeating: 0xCC, count: 1000)
        let fragments = FragmentSplitter.split(payload)
        #expect(fragments.count > 1)

        let assembler = FragmentAssembler()
        for (i, fragment) in fragments.enumerated() {
            let result = try assembler.receive(fragment)
            if i < fragments.count - 1 {
                guard case .incomplete(let received, let total) = result else {
                    Issue.record("Expected incomplete at index \(i)")
                    return
                }
                #expect(received == i + 1)
                #expect(total == fragments.count)
            } else {
                guard case .complete(let reassembled) = result else {
                    Issue.record("Expected complete at final index")
                    return
                }
                #expect(reassembled == payload)
            }
        }
        #expect(assembler.activeAssemblyCount == 0)
    }

    @Test("Out-of-order assembly completes correctly")
    func outOfOrderAssembly() throws {
        let payload = Data(repeating: 0xDD, count: 2000)
        let fragments = FragmentSplitter.split(payload)
        #expect(fragments.count > 2)

        let reversed = Array(fragments.reversed())
        let assembler = FragmentAssembler()
        var finalResult: FragmentAssemblyResult?

        for fragment in reversed {
            finalResult = try assembler.receive(fragment)
        }

        guard case .complete(let reassembled) = finalResult else {
            Issue.record("Expected complete after all fragments")
            return
        }
        #expect(reassembled == payload)
    }

    @Test("Duplicate fragment is rejected")
    func duplicateRejected() throws {
        let fragments = FragmentSplitter.split(Data(repeating: 0xEE, count: 1000))
        let assembler = FragmentAssembler()

        _ = try assembler.receive(fragments[0])
        #expect(throws: FragmentAssemblyError.self) {
            try assembler.receive(fragments[0])
        }
    }

    @Test("Inconsistent total is rejected")
    func inconsistentTotal() throws {
        let assembler = FragmentAssembler()
        let id = Data([0x01, 0x02, 0x03, 0x04])

        let frag1 = Fragment(fragmentID: id, index: 0, total: 5, data: Data([0xAA]))
        _ = try assembler.receive(frag1)

        let frag2 = Fragment(fragmentID: id, index: 1, total: 10, data: Data([0xBB]))
        #expect(throws: FragmentAssemblyError.self) {
            try assembler.receive(frag2)
        }
    }

    @Test("Multiple concurrent assemblies work")
    func concurrentAssemblies() throws {
        let assembler = FragmentAssembler()
        let payload1 = Data(repeating: 0x11, count: 1000)
        let payload2 = Data(repeating: 0x22, count: 1500)

        let frags1 = FragmentSplitter.split(payload1)
        let frags2 = FragmentSplitter.split(payload2)

        _ = try assembler.receive(frags1[0])
        _ = try assembler.receive(frags2[0])
        #expect(assembler.activeAssemblyCount == 2)

        _ = try assembler.receive(frags1[1])
        _ = try assembler.receive(frags2[1])

        var result1: FragmentAssemblyResult = .incomplete(received: 0, total: 0)
        for frag in frags1.dropFirst(2) {
            result1 = try assembler.receive(frag)
        }
        guard case .complete(let r1) = result1 else {
            Issue.record("Expected payload1 complete")
            return
        }
        #expect(r1 == payload1)

        var result2: FragmentAssemblyResult = .incomplete(received: 0, total: 0)
        for frag in frags2.dropFirst(2) {
            result2 = try assembler.receive(frag)
        }
        guard case .complete(let r2) = result2 else {
            Issue.record("Expected payload2 complete")
            return
        }
        #expect(r2 == payload2)
    }

    @Test("LRU eviction at max concurrent assemblies")
    func lruEviction() throws {
        let assembler = FragmentAssembler()

        for i in 0..<FragmentAssembler.maxConcurrentAssemblies {
            let id = withUnsafeBytes(of: UInt32(i).bigEndian) { Data($0) }
            let frag = Fragment(fragmentID: id, index: 0, total: 5, data: Data([UInt8(i % 256)]))
            _ = try assembler.receive(frag)
        }
        #expect(assembler.activeAssemblyCount == FragmentAssembler.maxConcurrentAssemblies)

        let newID = Data([0xFF, 0xFF, 0xFF, 0xFF])
        let newFrag = Fragment(fragmentID: newID, index: 0, total: 3, data: Data([0x99]))
        _ = try assembler.receive(newFrag)
        #expect(assembler.activeAssemblyCount == FragmentAssembler.maxConcurrentAssemblies)
    }

    @Test("Cancel removes assembly")
    func cancel() throws {
        let assembler = FragmentAssembler()
        let fragments = FragmentSplitter.split(Data(repeating: 0xAA, count: 1000))

        _ = try assembler.receive(fragments[0])
        #expect(assembler.activeAssemblyCount == 1)

        assembler.cancel(fragmentID: fragments[0].fragmentID)
        #expect(assembler.activeAssemblyCount == 0)
    }

    @Test("Reset clears all assemblies")
    func reset() throws {
        let assembler = FragmentAssembler()
        for i in 0..<5 {
            let id = withUnsafeBytes(of: UInt32(i).bigEndian) { Data($0) }
            let frag = Fragment(fragmentID: id, index: 0, total: 3, data: Data([0x42]))
            _ = try assembler.receive(frag)
        }
        #expect(assembler.activeAssemblyCount == 5)
        assembler.reset()
        #expect(assembler.activeAssemblyCount == 0)
    }

    @Test("Single-fragment assembly completes immediately")
    func singleFragment() throws {
        let assembler = FragmentAssembler()
        let payload = Data("small".utf8)
        let fragment = Fragment(
            fragmentID: Data([0x01, 0x02, 0x03, 0x04]),
            index: 0, total: 1, data: payload
        )

        let result = try assembler.receive(fragment)
        guard case .complete(let reassembled) = result else {
            Issue.record("Expected complete for single fragment")
            return
        }
        #expect(reassembled == payload)
        #expect(assembler.activeAssemblyCount == 0)
    }

    @Test("End-to-end: split -> serialize -> parse -> assemble")
    func endToEnd() throws {
        let originalPayload = Data(repeating: 0x77, count: 3000)
        let fragments = FragmentSplitter.split(originalPayload)
        let assembler = FragmentAssembler()
        var finalResult: FragmentAssemblyResult?

        for fragment in fragments {
            let wireData = fragment.serialize()
            let parsed = Fragment.parse(wireData)
            #expect(parsed != nil)
            finalResult = try assembler.receive(parsed!)
        }

        guard case .complete(let reassembled) = finalResult else {
            Issue.record("Expected complete after all fragments")
            return
        }
        #expect(reassembled == originalPayload)
    }

    @Test("Purge expired does not remove fresh assemblies")
    func purgeExpired() throws {
        let assembler = FragmentAssembler()
        let frag = Fragment(
            fragmentID: Data([0x01, 0x02, 0x03, 0x04]),
            index: 0, total: 5, data: Data([0xAA])
        )
        _ = try assembler.receive(frag)
        #expect(assembler.activeAssemblyCount == 1)

        let purged = assembler.purgeExpiredAssemblies()
        #expect(purged.isEmpty)
        #expect(assembler.activeAssemblyCount == 1)
    }
}
