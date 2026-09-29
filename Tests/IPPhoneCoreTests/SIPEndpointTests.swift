import Testing
@testable import IPPhoneCore

@MainActor
struct SIPEndpointTests {
    @Test
    func initializesAndStopsRealPJSIPEndpoint() throws {
        let endpoint = SIPEndpoint()

        #expect(!endpoint.pjsipVersion.isEmpty)
        try endpoint.startUDP(port: 0)

        guard case let .running(port) = endpoint.state else {
            Issue.record("Endpoint did not enter the running state")
            return
        }
        #expect(port > 0)

        endpoint.stop()
        #expect(endpoint.state == .stopped)
    }

    @Test
    func startsUDPRegistrationTransaction() throws {
        let endpoint = SIPEndpoint()
        try endpoint.startUDP(port: 0)
        defer { endpoint.stop() }

        let settings = SIPSettings(
            serverHost: "127.0.0.1",
            serverPort: 9,
            userID: "1001",
            phoneNumber: "1001",
            registrationExpiration: 300
        )
        try endpoint.register(settings: settings, password: "test-password")

        #expect(endpoint.registrationState == .registering)
    }
}
