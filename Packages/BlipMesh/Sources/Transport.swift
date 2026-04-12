import Foundation
import BlipProtocol

// MARK: - Transport errors

/// Errors that may occur across any transport implementation.
public enum TransportError: Error, Sendable, Equatable {
    /// The transport has not been started.
    case notStarted
    /// The transport is not connected to the specified peer.
    case peerNotConnected(PeerID)
    /// The data exceeds the transport's MTU.
    case payloadTooLarge(size: Int, max: Int)
    /// Transport-specific send failure.
    case sendFailed(String)
    /// The transport is not implemented (placeholder for future transports).
    case notImplemented
    /// The transport is currently unavailable (e.g., Bluetooth off).
    case unavailable(String)
}

// MARK: - Transport state

/// Represents the current operational state of a transport.
public enum TransportState: Sendable, Equatable {
    /// Transport is idle and has not been started.
    case idle
    /// Transport is in the process of starting (e.g., waiting for Bluetooth to power on).
    case starting
    /// Transport is running and can send/receive data.
    case running
    /// Transport has been stopped intentionally.
    case stopped
    /// Transport cannot start until Bluetooth authorization is restored.
    case unauthorized
    /// Transport encountered an error and is not operational.
    case failed(String)
}

// MARK: - Transport protocol

/// A transport layer that can send and receive binary data to/from peers.
///
/// Implementations include BLE mesh, WebSocket relay, and WiFi Direct (v2).
/// Each transport manages its own connection lifecycle and notifies its delegate
/// of incoming data and peer state changes.
public protocol Transport: AnyObject, Sendable {

    /// The delegate that receives transport events.
    var delegate: (any TransportDelegate)? { get set }

    /// The current state of this transport.
    var state: TransportState { get }

    /// Start the transport (begin scanning, advertising, connecting, etc.).
    func start()

    /// Stop the transport and tear down all connections.
    func stop()

    /// Send data to a specific peer.
    ///
    /// - Parameters:
    ///   - data: The binary data to send.
    ///   - peerID: The destination peer.
    /// - Throws: `TransportError` if the send fails.
    func send(data: Data, to peerID: PeerID) throws

    /// Broadcast data to all connected peers.
    ///
    /// - Parameter data: The binary data to broadcast.
    func broadcast(data: Data)

    /// The set of currently connected peer IDs.
    var connectedPeers: [PeerID] { get }
}

// MARK: - Transport delegate

/// Delegate protocol for receiving events from a `Transport`.
public protocol TransportDelegate: AnyObject, Sendable {

    /// Called when binary data is received from a peer.
    ///
    /// - Parameters:
    ///   - transport: The transport that received the data.
    ///   - data: The raw binary data.
    ///   - peerID: The sending peer's ID.
    func transport(_ transport: any Transport, didReceiveData data: Data, from peerID: PeerID)

    /// Called when a new peer connects.
    ///
    /// - Parameters:
    ///   - transport: The transport reporting the connection.
    ///   - peerID: The newly connected peer.
    func transport(_ transport: any Transport, didConnect peerID: PeerID)

    /// Called when a peer disconnects.
    ///
    /// - Parameters:
    ///   - transport: The transport reporting the disconnection.
    ///   - peerID: The disconnected peer.
    func transport(_ transport: any Transport, didDisconnect peerID: PeerID)

    /// Called when the transport's state changes.
    ///
    /// - Parameters:
    ///   - transport: The transport whose state changed.
    ///   - state: The new state.
    func transport(_ transport: any Transport, didChangeState state: TransportState)

    /// Called when queued wire data is permanently dropped after transport retries are exhausted.
    func transport(_ transport: any Transport, didFailDelivery data: Data, to peerID: PeerID?)
}

public extension TransportDelegate {
    func transport(_ transport: any Transport, didFailDelivery data: Data, to peerID: PeerID?) {}
}
