#if DEBUG
import SwiftUI
import SwiftData
import BlipMesh
import BlipProtocol
import os.log

// MARK: - BLE Debug Overlay

/// Debug-only overlay showing real BLE mesh state, peer table from SwiftData,
/// relay metrics, and a scrollable event log from DebugLogger.
///
/// Activated by triple-tapping the Nearby tab title.
struct BLEDebugOverlay: View {

    @State private var bleState: String = "Unknown"
    @State private var wsState: String = "Unknown"
    @State private var peerCount = 0
    @State private var meshPeers: [MeshPeer] = []
    @State private var copiedToast = false

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppCoordinator.self) private var coordinator

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BlipSpacing.md) {
                    transportSection
                    peerTableSection
                    relaySection
                    logSection
                }
                .padding(BlipSpacing.md)
            }
            .background(Color.black)
            .navigationTitle("BLE Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = DebugLogger.shared.exportText
                        copiedToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedToast = false }
                    } label: {
                        Label("Copy Log", systemImage: "doc.on.doc")
                            .font(.system(.caption, design: .monospaced))
                    }
                    .foregroundStyle(.blipAccentPurple)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.blipAccentPurple)
                }
            }
            .overlay(alignment: .top) {
                if copiedToast {
                    Text("Copied to clipboard")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, BlipSpacing.md)
                        .padding(.vertical, BlipSpacing.sm)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: copiedToast)
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

            HStack(spacing: BlipSpacing.lg) {
                metricBlock(label: "BLE Peers", value: "\(peerCount)")
                metricBlock(label: "SwiftData", value: "\(meshPeers.count)")
                metricBlock(label: "w/ Name", value: "\(meshPeers.filter { $0.username != nil }.count)")
            }
        }
    }

    // MARK: - Peer Table

    private var peerTableSection: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.sm) {
            sectionHeader("Peers (\(meshPeers.count))")

            if meshPeers.isEmpty {
                Text("No MeshPeer records")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.gray)
            } else {
                ForEach(meshPeers, id: \.id) { peer in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(peerIDShort(peer.peerID))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.white)

                            if let name = peer.username {
                                Text(name)
                                    .font(.system(.caption2, design: .monospaced))
                                    .fontWeight(.bold)
                                    .foregroundStyle(.green)
                            } else {
                                Text("nil")
                                    .font(.system(.caption2, design: .monospaced))
                                    .fontWeight(.bold)
                                    .foregroundStyle(.red)
                            }

                            Spacer()

                            Text(peer.connectionState.rawValue)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(peer.connectionState == .connected ? .green : .orange)
                        }

                        HStack {
                            Text("RSSI: \(peer.rssi)")
                                .foregroundStyle(rssiColor(peer.rssi))
                            Text("hop: \(peer.hopCount)")
                                .foregroundStyle(.gray)
                            Text("key: \(peer.noisePublicKey.isEmpty ? "empty" : peerIDShort(peer.noisePublicKey))")
                                .foregroundStyle(peer.noisePublicKey.isEmpty ? .red : .gray)
                            Spacer()
                            Text(relativeTime(peer.lastSeenAt))
                                .foregroundStyle(.gray)
                        }
                        .font(.system(size: 9, design: .monospaced))
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    // MARK: - Relay Metrics

    private var relaySection: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.sm) {
            sectionHeader("Relay")

            if let relay = coordinator.meshRelayService {
                let m = relay.metrics
                HStack(spacing: BlipSpacing.lg) {
                    metricBlock(label: "Received", value: "\(m.received)")
                    metricBlock(label: "Relayed", value: "\(m.relayed)")
                    metricBlock(label: "Dropped", value: "\(m.dropped)")
                }
            } else {
                Text("Relay not initialized")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.gray)
            }
        }
    }

    // MARK: - Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.sm) {
            HStack {
                sectionHeader("Log (\(DebugLogger.shared.entries.count))")
                Spacer()
                Button("Clear") { DebugLogger.shared.clear() }
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.blipAccentPurple)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(DebugLogger.shared.entries.prefix(50)) { entry in
                    HStack(alignment: .top, spacing: 4) {
                        Text(entry.formattedTime)
                            .foregroundStyle(.gray)
                        Text("[\(entry.category)]")
                            .foregroundStyle(categoryColor(entry.category))
                        Text(entry.message)
                            .foregroundStyle(entry.isError ? .red : .white)
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .lineLimit(2)
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

    private func categoryColor(_ cat: String) -> Color {
        switch cat {
        case "TX": return .cyan
        case "RX": return .green
        case "PEER": return .yellow
        case "SYNC": return .orange
        case "RELAY": return .purple
        default: return .gray
        }
    }

    private func peerIDShort(_ data: Data) -> String {
        data.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }

    // MARK: - State Refresh

    private func refreshState() {
        // Read real BLE state
        if let ble = coordinator.bleService {
            switch ble.state {
            case .idle: bleState = "Idle"
            case .starting: bleState = "Starting"
            case .running: bleState = "Running"
            case .stopped: bleState = "Stopped"
            case .failed(let reason): bleState = "Failed: \(reason)"
            }
            peerCount = ble.connectedPeers.count
        } else {
            bleState = "Not initialized"
        }

        if let ws = coordinator.webSocketTransport {
            switch ws.state {
            case .running: wsState = "Connected"
            case .starting: wsState = "Connecting"
            default: wsState = "Disconnected"
            }
        }

        // Read MeshPeer records from SwiftData
        let descriptor = FetchDescriptor<MeshPeer>(
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]
        )
        meshPeers = (try? modelContext.fetch(descriptor)) ?? []
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
#else
import SwiftUI

extension View {
    /// No-op in Release builds.
    func bleDebugOverlay() -> some View {
        self
    }
}
#endif
