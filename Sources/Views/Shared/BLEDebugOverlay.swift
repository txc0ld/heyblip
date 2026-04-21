import SwiftUI
import SwiftData
import BlipMesh
import BlipProtocol
import BlipCrypto
import os.log

// MARK: - BLE Debug Overlay

/// Debug-only overlay showing real BLE mesh state, in-memory peer table,
/// relay metrics, filtered log views, key status, and a scrollable event log.
///
/// Activated by triple-tapping the Nearby tab title.
struct BLEDebugOverlay: View {

    @State private var storePeers: [PeerInfo] = []
    @State private var copiedToast = false
    @State private var copiedDebugToast = false
    @State private var showShareSheet = false
    @State private var selectedTab: DebugTab = .log
    @State private var pendingHandshakes: [(peerHex: String, queuedMsgs: Int, isResponder: Bool)] = []

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppCoordinator.self) private var coordinator

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private enum DebugTab: String, CaseIterable {
        case log = "Log"
        case dmTrace = "DM Trace"
        case peerLife = "Peer Life"
        case noise = "Noise"
        case keys = "Keys"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BlipSpacing.md) {
                    buildBanner
                    transportSection
                    peerTableSection
                    relaySection
                    tabPicker
                    selectedTabContent
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
        let bleLabel = Self.bleLabel(for: coordinator.bleTransportState, hasService: coordinator.bleService != nil)
        let wsLabel = Self.webSocketLabel(for: coordinator.webSocketTransportState)

        return VStack(alignment: .leading, spacing: BlipSpacing.sm) {
            sectionHeader("Transport")

            HStack {
                statusDot(bleLabel == "Running" ? .green : (bleLabel == "Starting" ? .yellow : .red))
                Text("BLE: \(bleLabel)")
                Spacer()
                statusDot(wsLabel == "Connected" ? .green : (wsLabel == "Connecting" ? .yellow : .red))
                Text("WS: \(wsLabel)")
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.white)

            HStack(spacing: BlipSpacing.lg) {
                metricBlock(label: "BLE Peers", value: "\(coordinator.connectedBLEPeerCount)")
                metricBlock(label: "PeerStore", value: "\(storePeers.count)")
                metricBlock(label: "w/ Name", value: "\(storePeers.filter { $0.username != nil }.count)")
            }
        }
    }

    /// Renders a `TransportState` for the BLE indicator. Pure helper so it can be
    /// covered by unit tests without instantiating SwiftUI.
    static func bleLabel(for state: TransportState, hasService: Bool) -> String {
        guard hasService else { return "Not initialized" }
        switch state {
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .unauthorized: return "Unauthorized"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }

    /// Renders a `TransportState` for the WebSocket indicator.
    static func webSocketLabel(for state: TransportState) -> String {
        switch state {
        case .running: return "Connected"
        case .starting: return "Connecting"
        default: return "Disconnected"
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
                            Text(peer.hasSignalData ? "RSSI: \(peer.rssi)" : "RSSI: n/a")
                                .foregroundStyle(rssiColor(peer.rssi, hasSignalData: peer.hasSignalData))
                            Text("via: \(peer.transportType.rawValue)")
                                .foregroundStyle(.gray)
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
                    .padding(.vertical, BlipSpacing.xxs)
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

    // MARK: - Tab Picker

    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(DebugTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(.caption2, design: .monospaced))
                        .fontWeight(selectedTab == tab ? .bold : .regular)
                        .foregroundStyle(selectedTab == tab ? .white : .gray)
                        .padding(.vertical, BlipSpacing.sm)
                        .frame(maxWidth: .infinity)
                        .background(
                            selectedTab == tab
                                ? Color.blipAccentPurple.opacity(0.3)
                                : Color.clear
                        )
                }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .log:
            logSection
        case .dmTrace:
            dmTraceSection
        case .peerLife:
            peerLifecycleSection
        case .noise:
            noiseStatusSection
        case .keys:
            keyStatusSection
        }
    }

    // MARK: - Log (All)

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

            logEntryList(entries: Array(DebugLogger.shared.entries.prefix(50)))
        }
    }

    // MARK: - DM Send Trace

    private var dmTraceSection: some View {
        let dmEntries = DebugLogger.shared.entries
            .filter { $0.category == "DM" }
            .prefix(50)

        return VStack(alignment: .leading, spacing: BlipSpacing.sm) {
            sectionHeader("DM Send Trace (\(dmEntries.count))")

            if dmEntries.isEmpty {
                Text("No DM entries yet")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.gray)
            } else {
                logEntryList(entries: Array(dmEntries))
            }
        }
    }

    // MARK: - Peer Lifecycle

    private var peerLifecycleSection: some View {
        let peerCategories: Set<String> = ["PEER", "BLE", "MESH"]
        let peerEntries = DebugLogger.shared.entries
            .filter { peerCategories.contains($0.category) }
            .prefix(50)

        return VStack(alignment: .leading, spacing: BlipSpacing.sm) {
            sectionHeader("Peer Lifecycle (\(peerEntries.count))")

            if peerEntries.isEmpty {
                Text("No peer/BLE/mesh entries yet")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.gray)
            } else {
                logEntryList(entries: Array(peerEntries))
            }
        }
    }

    // MARK: - Noise Handshake Status

    private var noiseStatusSection: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.sm) {
            let noiseEntries = DebugLogger.shared.entries
                .filter { $0.category == "NOISE" || $0.category == "CRYPTO" }
                .prefix(30)

            sectionHeader("Noise Sessions")

            if pendingHandshakes.isEmpty {
                Text("No pending handshakes")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.gray)
            } else {
                ForEach(pendingHandshakes, id: \.peerHex) { hs in
                    HStack(spacing: BlipSpacing.sm) {
                        statusDot(hs.isResponder ? .yellow : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hs.peerHex)
                                .foregroundStyle(.white)
                            Text(hs.isResponder ? "responder — waiting msg3" : "initiator — waiting msg2")
                                .foregroundStyle(.gray)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(hs.queuedMsgs) msg(s)")
                                .foregroundStyle(hs.queuedMsgs > 0 ? .orange : .gray)
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .padding(.vertical, BlipSpacing.xxs)
                }
            }

            sectionHeader("Noise Log (\(noiseEntries.count))")

            if noiseEntries.isEmpty {
                Text("No NOISE/CRYPTO entries yet")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.gray)
            } else {
                logEntryList(entries: Array(noiseEntries))
            }
        }
    }

    // MARK: - Key Status

    private var keyStatusSection: some View {
        VStack(alignment: .leading, spacing: BlipSpacing.sm) {
            sectionHeader("Key Status")

            let keyManager = KeyManager.shared
            let identity = try? keyManager.loadIdentity()

            VStack(alignment: .leading, spacing: 6) {
                // Noise keypair
                HStack {
                    statusDot(identity != nil ? .green : .red)
                    Text("Noise keypair:")
                        .foregroundStyle(.gray)
                    if let identity {
                        let hex = identity.noisePublicKey.rawRepresentation
                            .prefix(4)
                            .map { String(format: "%02x", $0) }
                            .joined()
                        Text(hex)
                            .foregroundStyle(.white)
                    } else {
                        Text("missing")
                            .foregroundStyle(.red)
                    }
                }

                // Signing keypair
                HStack {
                    statusDot(identity?.signingPublicKey.isEmpty == false ? .green : .red)
                    Text("Signing keypair:")
                        .foregroundStyle(.gray)
                    if let identity, !identity.signingPublicKey.isEmpty {
                        let hex = identity.signingPublicKey
                            .prefix(4)
                            .map { String(format: "%02x", $0) }
                            .joined()
                        Text(hex)
                            .foregroundStyle(.white)
                    } else {
                        Text("missing")
                            .foregroundStyle(.red)
                    }
                }

                // Server sync status
                HStack {
                    let synced: Bool = {
                        if let user = fetchLocalUser(), !user.noisePublicKey.isEmpty {
                            return true
                        }
                        return false
                    }()
                    statusDot(synced ? .green : .orange)
                    Text("Keys in User model:")
                        .foregroundStyle(.gray)
                    Text(synced ? "yes" : "no / unknown")
                        .foregroundStyle(synced ? .green : .orange)
                }
            }
            .font(.system(.caption, design: .monospaced))
            .padding(BlipSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Shared Log Entry List

    private func logEntryList(entries: [DebugLogger.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(entries) { entry in
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

    private func rssiColor(_ rssi: Int, hasSignalData: Bool) -> Color {
        guard hasSignalData else { return .gray }
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
        case "MESH": return .indigo
        case "REGISTER": return .pink
        case "SELF_CHECK": return .pink
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

    private func fetchLocalUser() -> User? {
        let users = try? modelContext.fetch(FetchDescriptor<User>())
        return users?.min(by: { $0.createdAt < $1.createdAt })
    }

    // MARK: - State Dump

    private func dumpState() {
        let log = DebugLogger.shared
        let peerStore = coordinator.peerStore

        log.log("DB", "=== State Dump ===")

        // PeerStore
        let peers = peerStore.allPeers().sorted { $0.lastSeenAt > $1.lastSeenAt }
        let peerIDs = peers.map { peerIDShort($0.peerID) }.joined(separator: ", ")
        log.log("DB", "PeerStore: \(peers.count) peers [\(peerIDs)]")

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

        // Noise sessions
        let sessionDesc = FetchDescriptor<NoiseSessionModel>()
        let sessionCount = (try? modelContext.fetchCount(sessionDesc)) ?? 0
        log.log("DB", "Active Noise sessions: \(sessionCount)")

        // WebSocket status
        let wsConnected = coordinator.webSocketTransport?.state == .running
        log.log("DB", "WebSocket connected: \(wsConnected)")

        // BLE scanning status
        let bleRunning = coordinator.bleService?.state == .running
        let peripheralCount = coordinator.bleService?.connectedPeers.count ?? 0
        log.log("DB", "BLE scanning: \(bleRunning == true ? "yes" : "no"), peripherals: \(peripheralCount)")

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
        storePeers = coordinator.peerStore.allPeers().sorted { $0.lastSeenAt > $1.lastSeenAt }

        if let msgService = coordinator.messageService {
            // Snapshot pending entries under lock, then check responder state outside.
            let snapshot: [(Data, Int)] = msgService.lock.withLock {
                msgService.pendingHandshakeMessages.map { ($0.key, $0.value.count) }
            }
            pendingHandshakes = snapshot.map { (peerBytes, count) in
                let hex = peerBytes.prefix(4).map { String(format: "%02x", $0) }.joined()
                let isResponder = PeerID(bytes: peerBytes)
                    .map { msgService.noiseSessionManager?.hasPendingResponderHandshake(for: $0) == true } ?? false
                return (peerHex: hex, queuedMsgs: count, isResponder: isResponder)
            }
        }
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

/// Triple-tap gesture to show BLE debug overlay in debug and TestFlight builds.
struct BLEDebugTapModifier: ViewModifier {
    @State private var showDebug = false

    private var isEnabled: Bool {
        #if DEBUG
        return true
        #else
        return BuildInfo.isTestFlight
        #endif
    }

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 3) {
                guard isEnabled else { return }
                showDebug = true
            }
            .sheet(isPresented: $showDebug) {
                BLEDebugOverlay()
            }
    }
}

extension View {
    /// Adds a triple-tap gesture to show the BLE debug overlay in debug and TestFlight builds.
    func bleDebugOverlay() -> some View {
        modifier(BLEDebugTapModifier())
    }
}

#Preview {
    BLEDebugOverlay()
        .environment(AppCoordinator())
}
