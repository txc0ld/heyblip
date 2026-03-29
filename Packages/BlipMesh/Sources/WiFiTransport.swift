import Foundation
import BlipProtocol

/// WiFi Direct transport -- stub for v2 (spec Section 5.10).
///
/// WiFi Direct offers higher bandwidth (~250 Mbps vs BLE's ~2 Mbps) and longer
/// range (~200m vs ~50m) but requires explicit pairing on iOS (no background
/// discovery). Marked as future enhancement.
///
/// All methods in this implementation throw `TransportError.notImplemented`.
public final class WiFiTransport: Transport, @unchecked Sendable {

    // MARK: - Transport conformance

    public weak var delegate: (any TransportDelegate)?

    public private(set) var state: TransportState = .idle

    public var connectedPeers: [PeerID] {
        [] // Not implemented in v1.
    }

    // MARK: - Init

    public init() {}

    // MARK: - Lifecycle

    public func start() {
        // WiFi Direct is not available in v1.
        state = .failed("WiFi Direct transport not implemented (v2)")
        delegate?.transport(self, didChangeState: state)
    }

    public func stop() {
        state = .stopped
        delegate?.transport(self, didChangeState: state)
    }

    // MARK: - Data transfer

    public func send(data: Data, to peerID: PeerID) throws {
        throw TransportError.notImplemented
    }

    public func broadcast(data: Data) {
        // No-op in v1. WiFi Direct is not available.
    }
}
