import IPPhoneCore
import SwiftUI

@main
struct IPPhoneApp: App {
    @StateObject private var endpoint = SIPEndpoint()

    var body: some Scene {
        WindowGroup("IP Phone Test Client") {
            ContentView(endpoint: endpoint)
                .frame(minWidth: 520, minHeight: 340)
        }
    }
}

private struct ContentView: View {
    @ObservedObject var endpoint: SIPEndpoint

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("IP Phone Test Client")
                .font(.largeTitle)

            LabeledContent("PJSIP", value: endpoint.pjsipVersion)
            LabeledContent("Endpoint", value: stateDescription)

            HStack {
                Button("Start UDP endpoint") {
                    try? endpoint.startUDP()
                }
                .disabled(isRunning)

                Button("Stop") {
                    endpoint.stop()
                }
                .disabled(!isRunning)
            }

            Text("Milestone 1: PJSIP endpoint integration")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(28)
    }

    private var isRunning: Bool {
        if case .running = endpoint.state { true } else { false }
    }

    private var stateDescription: String {
        switch endpoint.state {
        case .stopped:
            "Stopped"
        case let .running(port):
            "UDP listening on port \(port)"
        case let .failed(message):
            "Failed: \(message)"
        }
    }
}
