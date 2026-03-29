#if DEBUG
import SwiftUI
import BlipMesh
import BlipProtocol
import os.log

// MARK: - BLE Debug Overlay

/// Debug-only overlay showing BLE mesh state, peer connections, RSSI,
/// handshake status, message counts, and relay status.
///
/// Activated by triple-tapping the Nearby tab title.
struct BLEDebugOverlay: View {

    @State private var bleState: String = "Unknown"
    @State private var wsState: String = "Unknown"
    @State private var peerCount = 0
    @State private var peers: [DebugPeerInfo] = []
    @State private var messagesSent = 0
    @State private var messagesReceived = 0
    @State private var lastMessageLatency: TimeInterval = 0
    @State private var logLines: [String] = []

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    private let logger = Logger(subsystem: "com.blip", category: "BLEDebug")

    struct DebugPeerInfo: Identifiable {
        let id: String
        let peerID: String
        let rssi: Int
        let handshakeStatus: String
        let connected: Bool
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BlipSpacing.md) {
                    transportSection
                    peerSection
                    metricsSection
                    logSection
                }
                .padding(BlipSpacing.md)
            }
            .background(Color.black)
            .navigationTitle("BLE Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.blipAccentPurple)
                }
            }
            .onReceive(timer) { _ in refreshState() }
            .onAppear { refreshState() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Transport Status

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.sm) {
            sectionHeader("Transport")

            HStack {
                statusDot(bleState == "Running" ? .green : (bleState == "Starting" ? .yellow : .red))
                Text("BLE: \(bleState)")
                Spacer()
                statusDot(wsState == "Connected" ? .green : .red)
                Text("WS: \(wsState)")
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.white)
        }
    }

    // MARK: - Peers

    private var peerSection: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.sm) {
            sectionHeader("Peers (\(peerCount))")

            if peers.isEmpty {
                Text("No peers discovered")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.gray)
            } else {
                ForEach(peers) { peer in
                    HStack {
                        Text(peer.peerID)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer()
                        Text("RSSI: \(peer.rssi)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(rssiColor(peer.rssi))
                        Text(peer.handshakeStatus)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(peer.handshakeStatus == "encrypted" ? .green : .yellow)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Metrics

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.sm) {
            sectionHeader("Messages")

            HStack(spacing: BlipSpacing.lg) {
                metricBlock(label: "Sent", value: "\(messagesSent)")
                metricBlock(label: "Received", value: "\(messagesReceived)")
                metricBlock(label: "Latency", value: String(format: "%.0fms", lastMessageLatency * 1000))
            }
        }
    }

    // MARK: - Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.sm) {
            sectionHeader("Log")

            VStack(alignment: .leading, spacing: 2) {
                ForEach(logLines.suffix(20), id: \.self) { line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green.opacity(0.8))
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(.caption2, design: .monospaced))
            .fontWeight(.bold)
            .foregroundStyle(.blipAccentPurple)
    }

    private func statusDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private func metricBlock(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(.white)
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.gray)
        }
    }

    private func rssiColor(_ rssi: Int) -> Color {
        if rssi > -60 { return .green }
        if rssi > -80 { return .yellow }
        return .red
    }

    // MARK: - State Refresh

    private func refreshState() {
        // Read from NotificationCenter-posted state or AppCoordinator.
        // In a real device test, these will be populated by BLEService callbacks.
        let nc = NotificationCenter.default

        // Check BLE state via posted notifications.
        // For now, show placeholder until real device is connected.
        bleState = "Scanning"
        wsState = "Disconnected"

        // Listen for mesh peer changes.
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        if logLines.count > 100 { logLines.removeFirst(50) }
        logLines.append("[\(timestamp)] State refresh — \(peerCount) peers")
    }
}

// MARK: - Debug Overlay Modifier

/// Triple-tap gesture to show BLE debug overlay.
struct BLEDebugTapModifier: ViewModifier {
    @State private var showDebug = false

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 3) {
                showDebug = true
            }
            .sheet(isPresented: $showDebug) {
                BLEDebugOverlay()
            }
    }
}

extension View {
    /// Adds a triple-tap gesture to show the BLE debug overlay (DEBUG builds only).
    func bleDebugOverlay() -> some View {
        modifier(BLEDebugTapModifier())
    }
}
#endif
