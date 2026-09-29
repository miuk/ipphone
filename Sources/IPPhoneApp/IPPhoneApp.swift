import AppKit
import Combine
import IPPhoneCore
import SwiftUI

@main
struct IPPhoneApp: App {
    @NSApplicationDelegateAdaptor(IPPhoneAppDelegate.self) private var appDelegate
    @StateObject private var logStore: AppLogStore
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var endpoint: SIPEndpoint

    init() {
        let logs = AppLogStore()
        _logStore = StateObject(wrappedValue: logs)
        _settingsStore = StateObject(wrappedValue: SettingsStore())
        _endpoint = StateObject(wrappedValue: SIPEndpoint(logStore: logs))
    }

    var body: some Scene {
        WindowGroup("IP Phone Test Client") {
            ContentView(endpoint: endpoint, settingsStore: settingsStore, logStore: logStore)
                .frame(minWidth: 760, minHeight: 560)
        }
    }
}

@MainActor
private final class IPPhoneAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Direct executable launches also need normal GUI activation behavior.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate()
    }
}

private enum AppSection: String, CaseIterable, Identifiable {
    case phone = "Phone"
    case settings = "Settings"
    case logs = "Logs"

    var id: Self { self }
    var icon: String {
        switch self {
        case .phone: "phone"
        case .settings: "gearshape"
        case .logs: "text.alignleft"
        }
    }
}

private struct ContentView: View {
    @ObservedObject var endpoint: SIPEndpoint
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var logStore: AppLogStore
    @State private var selection: AppSection? = .phone
    private let pollTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon)
            }
            .navigationTitle("IP Phone")
        } detail: {
            switch selection ?? .phone {
            case .phone:
                PhoneView(endpoint: endpoint, settingsStore: settingsStore, logs: logStore)
            case .settings:
                SettingsView(store: settingsStore, logs: logStore)
            case .logs:
                LogView(store: logStore)
            }
        }
        .onReceive(pollTimer) { _ in endpoint.poll() }
    }
}

private struct PhoneView: View {
    @ObservedObject var endpoint: SIPEndpoint
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var logs: AppLogStore
    @State private var destination = ""
    @State private var dtmfStatus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("IP Phone Test Client").font(.largeTitle)
            LabeledContent("PJSIP", value: endpoint.pjsipVersion)
            LabeledContent("Endpoint", value: stateDescription)
            LabeledContent("Local SIP IP", value: endpoint.activeLocalIPAddress ?? "Automatic")
            if isRunning && !transportMatches {
                Label("Stop and restart the endpoint to apply the transport or local IP change.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            LabeledContent("Server", value: serverDescription)
            LabeledContent("Address of Record", value: settingsStore.settings.addressOfRecord ?? "Not configured")
            LabeledContent("Registration", value: registrationDescription)
            LabeledContent("Call", value: callDescription)
            LabeledContent("Media", value: mediaDescription)

            HStack {
                Button("Start \(settingsStore.settings.transport.rawValue) endpoint") {
                    startEndpoint()
                }
                .disabled(isRunning)
                Button("Stop") { endpoint.stop() }.disabled(!isRunning)
            }
            HStack {
                Button("Register") { register() }
                    .disabled(!canRegister)
                    .keyboardShortcut("r", modifiers: .command)
                Button("Unregister") { unregister() }
                    .disabled(!canUnregister)
            }
            Divider()
            TextField("Destination number or SIP URI", text: $destination)
                .textFieldStyle(.roundedBorder)
                .disabled(hasActiveCall)
                .onSubmit { makeCall() }
            HStack {
                Button("Call") { makeCall() }
                    .disabled(!canMakeCall)
                    .keyboardShortcut(.return, modifiers: [])
                if isIncoming {
                    Button("Answer") { answerCall() }
                        .buttonStyle(.borderedProminent)
                    Button("Reject") { endCall(statusCode: 486) }
                } else {
                    Button("Hang Up") { endCall() }.disabled(!hasActiveCall)
                }
                Button(endpoint.isMuted ? "Unmute" : "Mute") {
                    endpoint.setMuted(!endpoint.isMuted)
                }
                .disabled(!isMediaActive)
            }
            if isMediaActive {
                LabeledContent(
                    "RTP",
                    value: "TX \(endpoint.rtpStatistics.transmittedPackets) / RX \(endpoint.rtpStatistics.receivedPackets) / Lost \(endpoint.rtpStatistics.lostPackets) / Jitter \(endpoint.rtpStatistics.jitterMicroseconds) μs"
                )
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("DTMF").font(.headline)
                        Text(dtmfCapabilityDescription).foregroundStyle(.secondary)
                    }
                    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]], id: \.self) { row in
                            GridRow {
                                ForEach(row, id: \.self) { digit in
                                    Button(digit) { sendDTMF(digit) }
                                        .frame(minWidth: 48)
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    if !dtmfStatus.isEmpty {
                        Text(dtmfStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if isIncoming {
                Label("Incoming call", systemImage: "phone.arrow.down.left")
                    .font(.title2).foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(28)
        .navigationTitle("Phone")
    }

    private var isRunning: Bool {
        if case .running = endpoint.state { true } else { false }
    }

    private var stateDescription: String {
        switch endpoint.state {
        case .stopped: "Stopped"
        case let .running(port): "\(endpoint.activeTransport?.rawValue ?? "SIP") listening on port \(port)"
        case let .failed(message): "Failed: \(message)"
        }
    }

    private var serverDescription: String {
        let settings = settingsStore.settings
        guard !settings.serverHost.isEmpty else { return "Not configured" }
        return "\(settings.transport.rawValue) \(settings.serverHost):\(settings.serverPort)"
    }

    private var registrationDescription: String {
        switch endpoint.registrationState {
        case .unregistered: "Unregistered"
        case .registering: "Registering…"
        case let .registered(expiration): "Registered (expires in \(expiration)s)"
        case .unregistering: "Unregistering…"
        case let .failed(code, message): code == 0 ? "Failed: \(message)" : "Failed (SIP \(code)): \(message)"
        }
    }

    private var canRegister: Bool {
        settingsStore.settings.validationIssues().isEmpty
            && transportMatches
            && endpoint.registrationState != .registering
            && endpoint.registrationState != .unregistering
            && !isRegistered
    }

    private var canUnregister: Bool {
        if case .registered = endpoint.registrationState { true } else { false }
    }

    private var callDescription: String {
        switch endpoint.callState {
        case .idle: "Idle"
        case let .outgoing(remote): "Calling \(remote)…"
        case let .ringing(remote): "Ringing \(remote)…"
        case let .incoming(remote): "Incoming from \(remote)"
        case let .connected(remote): "Connected to \(remote)"
        case .disconnecting: "Disconnecting…"
        case let .ended(code, message): "Ended (SIP \(code)): \(message)"
        case let .failed(code, message): code == 0 ? "Failed: \(message)" : "Failed (SIP \(code)): \(message)"
        }
    }

    private var canMakeCall: Bool {
        !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !hasActiveCall
            && settingsStore.settings.validationIssues().isEmpty
            && transportMatches
    }

    private var mediaDescription: String {
        switch endpoint.mediaState {
        case .idle: "Idle"
        case .starting: "Starting…"
        case let .active(codec): "\(codec) send/receive"
        case let .failed(message): "Failed: \(message)"
        }
    }

    private var isMediaActive: Bool {
        if case .active = endpoint.mediaState { true } else { false }
    }

    private var dtmfCapabilityDescription: String {
        let configured = settingsStore.settings.dtmfMode
        if configured == .telephoneEvent && !endpoint.telephoneEventAvailable {
            return "telephone-event unavailable; automatic in-band fallback"
        }
        return configured.rawValue
    }

    private var hasActiveCall: Bool {
        switch endpoint.callState {
        case .outgoing, .ringing, .incoming, .connected, .disconnecting: true
        case .idle, .ended, .failed: false
        }
    }

    private var isIncoming: Bool {
        if case .incoming = endpoint.callState { true } else { false }
    }

    private var isRegistered: Bool {
        if case .registered = endpoint.registrationState { true } else { false }
    }

    private var transportMatches: Bool {
        !isRunning || (endpoint.activeTransport == settingsStore.settings.transport
            && endpoint.activeLocalIPAddress == settingsStore.settings.localIPAddress)
    }

    private func startEndpoint() {
        do {
            try startEndpointForCurrentSettings()
        } catch {
            logs.append(.error, category: "SIP", error.localizedDescription)
        }
    }

    private func register() {
        do {
            if !isRunning { try startEndpointForCurrentSettings() }
            try endpoint.register(settings: settingsStore.settings, password: settingsStore.password)
        } catch {
            logs.append(.error, category: "REGISTER", error.localizedDescription)
        }
    }

    private func unregister() {
        do { try endpoint.unregister() }
        catch { logs.append(.error, category: "REGISTER", error.localizedDescription) }
    }

    private func makeCall() {
        do {
            if !isRunning { try startEndpointForCurrentSettings() }
            try endpoint.makeCall(
                destination: destination,
                settings: settingsStore.settings,
                password: settingsStore.password
            )
        } catch {
            logs.append(.error, category: "Call", error.localizedDescription)
        }
    }

    private func answerCall() {
        do { try endpoint.answerCall() }
        catch { logs.append(.error, category: "Call", error.localizedDescription) }
    }

    private func endCall(statusCode: Int = 603) {
        do { try endpoint.endCall(statusCode: statusCode) }
        catch { logs.append(.error, category: "Call", error.localizedDescription) }
    }

    private func sendDTMF(_ text: String) {
        guard let digit = text.first else { return }
        do {
            let result = try endpoint.sendDTMF(digit, mode: settingsStore.settings.dtmfMode)
            dtmfStatus = result.usedFallback
                ? "Sent \(digit) using in-band fallback"
                : "Sent \(digit) using \(result.usedMode.rawValue)"
        } catch {
            dtmfStatus = error.localizedDescription
        }
    }

    private func startEndpointForCurrentSettings() throws {
        try endpoint.start(
            transport: settingsStore.settings.transport,
            port: UInt16(exactly: settingsStore.settings.localSIPPort) ?? 0,
            rtpPort: UInt16(exactly: settingsStore.settings.rtpPortStart) ?? 4_000,
            audioInputDevice: Int32(exactly: settingsStore.settings.audioInputDeviceIndex ?? -1) ?? -1,
            audioOutputDevice: Int32(exactly: settingsStore.settings.audioOutputDeviceIndex ?? -1) ?? -1,
            allowSelfSignedCertificate: settingsStore.settings.allowSelfSignedCertificate,
            localIPAddress: settingsStore.settings.localIPAddress
        )
    }
}

private struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var logs: AppLogStore
    @State private var issues: [SIPSettingsValidationIssue] = []
    @State private var saved = false
    @State private var localAddresses: [LocalIPAddress] = []
    @State private var addressError: String?

    var body: some View {
        Form {
            Section("SIP Server") {
                TextField("Host or IP address", text: $store.settings.serverHost)
                TextField("Port", value: $store.settings.serverPort, format: .number)
                Picker("Transport", selection: transportBinding) {
                    ForEach(SIPTransport.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("Local SIP port (0 = automatic)", value: $store.settings.localSIPPort, format: .number)
                Picker("Local IP for SIP headers", selection: $store.settings.localIPAddress) {
                    Text("Automatic").tag(nil as String?)
                    ForEach(localAddresses) { item in
                        Text("\(item.address) (\(item.interfaceName))").tag(Optional(item.address))
                    }
                    if let selected = store.settings.localIPAddress,
                       !localAddresses.contains(where: { $0.address == selected }) {
                        Text("\(selected) (unavailable)").tag(Optional(selected))
                    }
                }
                Button("Refresh local IP addresses") { refreshLocalAddresses() }
                Text("Used for Via, Contact and SDP. Stop and restart the endpoint after changing this setting. IPv6 link-local addresses are excluded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let addressError {
                    Text(addressError).foregroundStyle(.red)
                }
                TextField("Outbound proxy (optional)", text: $store.settings.outboundProxy)
            }

            Section("Account") {
                TextField("User ID", text: $store.settings.userID)
                SecureField("Password", text: $store.password)
                TextField("Phone number", text: $store.settings.phoneNumber)
                TextField("SIP domain (optional)", text: $store.settings.sipDomain)
                TextField("Display name", text: $store.settings.displayName)
                TextField("REGISTER expiration (seconds)", value: $store.settings.registrationExpiration, format: .number)
            }

            Section("Media") {
                Picker("DTMF", selection: $store.settings.dtmfMode) {
                    ForEach(DTMFMode.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("RTP first port", value: $store.settings.rtpPortStart, format: .number)
                TextField("RTP last port", value: $store.settings.rtpPortEnd, format: .number)
                TextField(
                    "Input device index (blank = default)",
                    value: $store.settings.audioInputDeviceIndex,
                    format: .number
                )
                TextField(
                    "Output device index (blank = default)",
                    value: $store.settings.audioOutputDeviceIndex,
                    format: .number
                )
            }

            Section("TLS") {
                Toggle(
                    "Allow self-signed certificates (disable server verification)",
                    isOn: $store.settings.allowSelfSignedCertificate
                )
                Picker("URI scheme", selection: $store.settings.tlsURIScheme) {
                    ForEach(TLSURIScheme.allCases) { Text("\($0.rawValue):").tag($0) }
                }
                .disabled(store.settings.transport != .tls)
            }

            if !issues.isEmpty {
                Section("Validation") {
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                        Label(issue.message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
            }

            if let error = store.lastError {
                Section("Storage Error") { Text(error).foregroundStyle(.red) }
            }

            HStack {
                Button("Save") { save() }.keyboardShortcut("s", modifiers: .command)
                if saved { Label("Saved", systemImage: "checkmark.circle").foregroundStyle(.green) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { refreshLocalAddresses() }
    }

    private func refreshLocalAddresses() {
        do {
            localAddresses = try LocalIPAddress.available()
            addressError = nil
        } catch {
            addressError = "Could not list local IP addresses: \(error.localizedDescription)"
        }
    }

    private var transportBinding: Binding<SIPTransport> {
        Binding(get: { store.settings.transport }, set: { store.settings.selectTransport($0) })
    }

    private func save() {
        issues = store.save()
        saved = issues.isEmpty && store.lastError == nil
        logs.append(
            saved ? .info : .warning,
            category: "Settings",
            saved ? "Settings saved for user \(store.settings.userID)" : "Settings validation or persistence failed"
        )
    }
}

private struct LogView: View {
    @ObservedObject var store: AppLogStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Application Log").font(.title2)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.exportedText, forType: .string)
                }
                Button("Clear") { store.clear() }
            }
            .padding()
            Divider()
            List(store.entries) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(entry.level.rawValue).font(.caption.monospaced()).foregroundStyle(color(entry.level))
                        Text(entry.category).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.timestamp, format: .dateTime.hour().minute().second())
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Text(entry.message).textSelection(.enabled).font(.system(.body, design: .monospaced))
                }
            }
            .overlay {
                if store.entries.isEmpty { ContentUnavailableView("No Logs", systemImage: "text.alignleft") }
            }
        }
        .navigationTitle("Logs")
    }

    private func color(_ level: AppLogLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}
