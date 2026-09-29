import AppKit
import IPPhoneCore
import SwiftUI

@main
struct IPPhoneApp: App {
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

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon)
            }
            .navigationTitle("IP Phone")
        } detail: {
            switch selection ?? .phone {
            case .phone:
                PhoneView(endpoint: endpoint, settings: settingsStore.settings)
            case .settings:
                SettingsView(store: settingsStore, logs: logStore)
            case .logs:
                LogView(store: logStore)
            }
        }
    }
}

private struct PhoneView: View {
    @ObservedObject var endpoint: SIPEndpoint
    let settings: SIPSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("IP Phone Test Client").font(.largeTitle)
            LabeledContent("PJSIP", value: endpoint.pjsipVersion)
            LabeledContent("Endpoint", value: stateDescription)
            LabeledContent("Server", value: serverDescription)
            LabeledContent("Address of Record", value: settings.addressOfRecord ?? "Not configured")

            HStack {
                Button("Start UDP endpoint") {
                    try? endpoint.startUDP(port: UInt16(exactly: settings.localSIPPort) ?? 0)
                }
                .disabled(isRunning || settings.transport != .udp)
                Button("Stop") { endpoint.stop() }.disabled(!isRunning)
            }
            Text("REGISTER will be implemented in milestone 3.").foregroundStyle(.secondary)
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
        case let .running(port): "UDP listening on port \(port)"
        case let .failed(message): "Failed: \(message)"
        }
    }

    private var serverDescription: String {
        guard !settings.serverHost.isEmpty else { return "Not configured" }
        return "\(settings.transport.rawValue) \(settings.serverHost):\(settings.serverPort)"
    }
}

private struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var logs: AppLogStore
    @State private var issues: [SIPSettingsValidationIssue] = []
    @State private var saved = false

    var body: some View {
        Form {
            Section("SIP Server") {
                TextField("Host or IP address", text: $store.settings.serverHost)
                TextField("Port", value: $store.settings.serverPort, format: .number)
                Picker("Transport", selection: transportBinding) {
                    ForEach(SIPTransport.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("Local SIP port (0 = automatic)", value: $store.settings.localSIPPort, format: .number)
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
            }

            Section("TLS") {
                Toggle("Allow self-signed certificates", isOn: $store.settings.allowSelfSignedCertificate)
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
