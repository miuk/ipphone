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
}
