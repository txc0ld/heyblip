import Foundation

/// Errors from fragment assembly.
public enum FragmentAssemblyError: Error, Sendable, Equatable {
    case tooManyConcurrentAssemblies
    case duplicateFragment(fragmentID: Data, index: UInt16)
    case assemblyTimedOut(fragmentID: Data)
    case inconsistentTotal(fragmentID: Data, expected: UInt16, got: UInt16)
}

/// Result of feeding a fragment into the assembler.
public enum FragmentAssemblyResult: Sendable, Equatable {
    /// Fragment accepted, assembly still in progress.
    case incomplete(received: Int, total: Int)
    /// All fragments received; here is the reassembled payload.
    case complete(Data)
}

/// Reassembles fragments into complete payloads.
///
/// Per spec Section 5.7:
/// - Max 128 concurrent fragment assemblies per peer
/// - Fragment lifetime: 30 seconds
/// - LRU eviction when the limit is exceeded
public final class FragmentAssembler: Sendable {

    /// Maximum concurrent assemblies.
    public static let maxConcurrentAssemblies = 128

    /// Fragment lifetime in seconds.
    public static let fragmentLifetime: TimeInterval = 30.0

    /// Internal assembly state for one fragment group.
    private final class Assembly: @unchecked Sendable {
        let fragmentID: Data
        let total: UInt16
        var fragments: [UInt16: Data]
        let createdAt: Date
        var lastAccessedAt: Date

        init(fragmentID: Data, total: UInt16) {
            self.fragmentID = fragmentID
            self.total = total
            self.fragments = [:]
            self.createdAt = Date()
            self.lastAccessedAt = Date()
        }

        var isComplete: Bool {
            fragments.count == Int(total)
        }

        var isExpired: Bool {
            Date().timeIntervalSince(createdAt) > FragmentAssembler.fragmentLifetime
        }

        /// Reassemble all fragments in index order.
        func reassemble() -> Data {
            var result = Data()
            for i in 0 ..< total {
                if let chunk = fragments[i] {
                    result.append(chunk)
                }
            }
            return result
        }
    }

    /// Lock for thread-safe access to assemblies.
    private let lock = NSLock()

    /// Active assemblies keyed by fragmentID.
    // Protected by `lock`; mutable access is always serialized.
    private nonisolated(unsafe) var assemblies: [Data: Assembly] = [:]

    /// Ordered list of fragment IDs for LRU eviction.
    // Protected by `lock`; mutable access is always serialized.
    private nonisolated(unsafe) var lruOrder: [Data] = []

    public init() {}

    // MARK: - Public API

    /// Feed a fragment into the assembler.
    ///
    /// - Returns: `.incomplete` if more fragments are needed, `.complete` with the
    ///   reassembled payload when all fragments have arrived.
    /// - Throws: `FragmentAssemblyError` on duplicate fragments, assembly limit exceeded
    ///   (after eviction), or inconsistent total counts.
    public func receive(_ fragment: Fragment) throws -> FragmentAssemblyResult {
        lock.lock()
        defer { lock.unlock() }

        // Purge expired assemblies first.
        purgeExpired()

        if let existing = assemblies[fragment.fragmentID] {
            // Validate consistent total
            guard existing.total == fragment.total else {
                throw FragmentAssemblyError.inconsistentTotal(
                    fragmentID: fragment.fragmentID,
                    expected: existing.total,
                    got: fragment.total
                )
            }

            // Check for duplicate
            guard existing.fragments[fragment.index] == nil else {
                throw FragmentAssemblyError.duplicateFragment(
                    fragmentID: fragment.fragmentID,
                    index: fragment.index
                )
            }

            // Add fragment
            existing.fragments[fragment.index] = fragment.data
            existing.lastAccessedAt = Date()
            touchLRU(fragment.fragmentID)

            if existing.isComplete {
                let payload = existing.reassemble()
                removeAssembly(fragment.fragmentID)
                return .complete(payload)
            }

            return .incomplete(
                received: existing.fragments.count,
                total: Int(existing.total)
            )
        } else {
            // New assembly
            if assemblies.count >= FragmentAssembler.maxConcurrentAssemblies {
                evictLRU()
            }

            let assembly = Assembly(fragmentID: fragment.fragmentID, total: fragment.total)
            assembly.fragments[fragment.index] = fragment.data
            assemblies[fragment.fragmentID] = assembly
            lruOrder.append(fragment.fragmentID)

            if assembly.isComplete {
                let payload = assembly.reassemble()
                removeAssembly(fragment.fragmentID)
                return .complete(payload)
            }

            return .incomplete(
                received: assembly.fragments.count,
                total: Int(assembly.total)
            )
        }
    }

    /// Cancel and remove a specific assembly.
    public func cancel(fragmentID: Data) {
        lock.lock()
        defer { lock.unlock() }
        removeAssembly(fragmentID)
    }

    /// Remove all assemblies.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        assemblies.removeAll()
        lruOrder.removeAll()
    }

    /// Number of active assemblies.
    public var activeAssemblyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return assemblies.count
    }

    /// Purge expired assemblies and return their fragment IDs.
    @discardableResult
    public func purgeExpiredAssemblies() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return purgeExpired()
    }

    // MARK: - Internal

    @discardableResult
    private func purgeExpired() -> [Data] {
        var purged: [Data] = []
        for (id, assembly) in assemblies {
            if assembly.isExpired {
                purged.append(id)
            }
        }
        for id in purged {
            removeAssembly(id)
        }
        return purged
    }

    private func evictLRU() {
        guard let oldest = lruOrder.first else { return }
        removeAssembly(oldest)
    }

    private func removeAssembly(_ fragmentID: Data) {
        assemblies.removeValue(forKey: fragmentID)
        lruOrder.removeAll { $0 == fragmentID }
    }

    private func touchLRU(_ fragmentID: Data) {
        lruOrder.removeAll { $0 == fragmentID }
        lruOrder.append(fragmentID)
    }
}
