#if DEBUG
import SwiftUI
import SwiftData
import BlipMesh
import BlipProtocol
import os.log

// MARK: - BLE Debug Overlay

/// Debug-only overlay showing real BLE mesh state, in-memory peer table,
/// relay metrics, and a scrollable event log from DebugLogger.
///
/// Activated by triple-tapping the Nearby tab title.
struct BLEDebugOverlay: View {

    @State private var bleState: String = "Unknown"
    @State private var wsState: String = "Unknown"
    @State private var peerCount = 0
    @State private var storePeers: [PeerInfo] = []
    @State private var copiedToast = false
    @State private var copiedDebugToast = false
    @State private var showShareSheet = false

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppCoordinator.self) private var coordinator

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BlipSpacing.md) {
                    buildBanner
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
                    HStack(spacing: BlipSpacing.sm) {
                        Button {
                            UIPasteboard.general.string = DebugLogger.shared.exportText
                            copiedToast = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedToast = false }
                        } label: {
                            Label("Copy Log", systemImage: "doc.on.doc")
                                .font(.system(.caption, design: .monospaced))
                        }
                        .foregroundStyle(.blipAccentPurple)

                        Button {
                            showShareSheet = true
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.system(.caption, design: .monospaced))
                        }
                        .foregroundStyle(.blipAccentPurple)

                        Button {
                            UIPasteboard.general.string = DebugLogger.shared.exportTextForDebug
                            copiedDebugToast = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedDebugToast = false }
                        } label: {
                            Label("Copy for Debug", systemImage: "ladybug")
                                .font(.system(.caption, design: .monospaced))
                        }
                        .foregroundStyle(.blipAccentPurple)
                    }
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
                if copiedDebugToast {
                    Text("Debug log copied")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, BlipSpacing.md)
                        .padding(.vertical, BlipSpacing.sm)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: copiedToast)
            .animation(.easeInOut(duration: 0.2), value: copiedDebugToast)
            .onReceive(timer) { _ in refreshState() }
            .onAppear { refreshState() }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(text: DebugLogger.shared.exportText)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Build Banner

    private var buildBanner: some View {
        Text(BuildInfo.fullBuildString)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.gray)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BlipSpacing.sm)
            .padding(.vertical, BlipSpacing.xs)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
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
                metricBlock(label: "PeerStore", value: "\(storePeers.count)")
                metricBlock(label: "w/ Name", value: "\(storePeers.filter { $0.username != nil }.count)")
            }
        }
    }

    // MARK: - Peer Table

    private var peerTableSection: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.sm) {
            sectionHeader("Peers (\(storePeers.count))")

            if storePeers.isEmpty {
                Text("No peers in PeerStore")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.gray)
            } else {
                ForEach(storePeers, id: \.peerID) { peer in
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

                            Text(peer.isConnected ? "connected" : "disconnected")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(peer.isConnected ? .green : .orange)
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
                Button("Dump State") { dumpState() }
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.mint)
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
        case "DM": return .mint
        case "BLE": return .blue
        case "DB": return .teal
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

    // MARK: - State Dump

    private func dumpState() {
        let log = DebugLogger.shared
        let peerStore = coordinator.peerStore

        // PeerStore records
        let peers = peerStore.allPeers().sorted { $0.lastSeenAt > $1.lastSeenAt }
        log.log("DB", "=== State Dump ===")
        log.log("DB", "PeerStore: \(peers.count) peers")
        let blePeerIDs = Set((coordinator.bleService?.connectedPeers ?? []).map { $0.bytes })
        var orphanCount = 0
        for peer in peers {
            let shortID = peer.peerID.prefix(4).map { String(format: "%02x", $0) }.joined()
            let name = peer.username ?? "nil"
            let state = peer.isConnected ? "connected" : "disconnected"
            let age = relativeTime(peer.lastSeenAt)
            let hasBLE = blePeerIDs.contains(peer.peerID)
            let orphan = peer.isConnected && !hasBLE
            if orphan { orphanCount += 1 }
            log.log("DB", "  \(shortID) \(name) state=\(state) seen=\(age)\(orphan ? " ORPHAN" : "")")
        }

        // Conversations and messages
        let channelDesc = FetchDescriptor<Channel>()
        let channels = (try? modelContext.fetch(channelDesc)) ?? []
        let messageDesc = FetchDescriptor<Message>()
        let messages = (try? modelContext.fetch(messageDesc)) ?? []
        log.log("DB", "Channels: \(channels.count) Messages: \(messages.count)")

        if orphanCount > 0 {
            log.log("DB", "\(orphanCount) orphaned peer(s): marked connected but no BLE mapping", isError: true)
        }
        log.log("DB", "=== End Dump ===")
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

        // Read from in-memory PeerStore
        storePeers = coordinator.peerStore.allPeers().sorted { $0.lastSeenAt > $1.lastSeenAt }
    }
}

// MARK: - Share Sheet

/// UIActivityViewController wrapper for sharing debug log text.
private struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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
