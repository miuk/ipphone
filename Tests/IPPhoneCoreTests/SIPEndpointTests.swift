import Darwin
import Testing
@testable import IPPhoneCore

@Suite(.serialized)
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
    func startsTCPAndTLSTransports() throws {
        for transport in [SIPTransport.tcp, .tls] {
            let endpoint = SIPEndpoint()
            try endpoint.start(transport: transport, port: 0)
            guard case let .running(port) = endpoint.state else {
                Issue.record("\(transport.rawValue) endpoint did not enter the running state")
                continue
            }
            #expect(port > 0)
            #expect(endpoint.activeTransport == transport)

            let settings = SIPSettings(
                serverHost: "127.0.0.1",
                serverPort: 9,
                transport: transport,
                userID: "1001",
                phoneNumber: "1001"
            )
            try endpoint.register(settings: settings, password: "test-password")
            #expect(endpoint.registrationState == .registering)
            endpoint.stop()
            #expect(endpoint.state == .stopped)
        }
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

    @Test
    func sendsOutgoingInviteAndStartsCancellation() throws {
        let endpoint = SIPEndpoint()
        try endpoint.startUDP(port: 0)
        defer { endpoint.stop() }
        let settings = SIPSettings(
            serverHost: "127.0.0.1",
            serverPort: 9,
            userID: "1001",
            phoneNumber: "1001"
        )

        try endpoint.makeCall(destination: "1002", settings: settings, password: "test-password")
        guard case .outgoing = endpoint.callState else {
            Issue.record("Call did not enter outgoing state")
            return
        }

        try endpoint.endCall()
        #expect(endpoint.callState == .disconnecting)
    }

    @Test
    func receivesAndRejectsIncomingInvite() throws {
        let endpoint = SIPEndpoint()
        try endpoint.startUDP(port: 0)
        defer { endpoint.stop() }
        guard case let .running(port) = endpoint.state else {
            Issue.record("Endpoint did not start")
            return
        }

        try sendInvite(to: port)
        for _ in 0..<20 {
            endpoint.poll()
            if case .incoming = endpoint.callState { break }
            usleep(10_000)
        }

        guard case let .incoming(remoteURI) = endpoint.callState else {
            Issue.record("Call did not enter incoming state")
            return
        }
        #expect(remoteURI.contains("2002"))

        try endpoint.endCall(statusCode: 486)
        guard case .ended(statusCode: 486, _) = endpoint.callState else {
            Issue.record("Rejected call did not enter ended state")
            return
        }
    }

    @Test
    func receivesAndAnswersIncomingInvite() throws {
        let endpoint = SIPEndpoint()
        try endpoint.startUDP(port: 0)
        defer { endpoint.stop() }
        guard case let .running(port) = endpoint.state else {
            Issue.record("Endpoint did not start")
            return
        }

        try sendInvite(to: port)
        for _ in 0..<20 {
            endpoint.poll()
            if case .incoming = endpoint.callState { break }
            usleep(10_000)
        }
        guard case .incoming = endpoint.callState else {
            Issue.record("Call did not enter incoming state")
            return
        }

        try endpoint.answerCall()
        endpoint.poll()
        guard case .connected = endpoint.callState else {
            Issue.record("Answered call did not enter connected state")
            return
        }
        guard case .active(codec: "PCMU/8000") = endpoint.mediaState else {
            Issue.record("PCMU media did not become active")
            return
        }
        endpoint.setMuted(true)
        #expect(endpoint.isMuted)
        endpoint.setMuted(false)
        #expect(!endpoint.isMuted)

        #expect(!endpoint.telephoneEventAvailable)
        let fallback = try endpoint.sendDTMF("5", mode: .telephoneEvent, durationMilliseconds: 100)
        #expect(fallback.requestedMode == .telephoneEvent)
        #expect(fallback.usedMode == .inBand)
        #expect(fallback.usedFallback)
    }

    @Test
    func sendsNegotiatedTelephoneEvent() throws {
        let endpoint = SIPEndpoint()
        try endpoint.startUDP(port: 0)
        defer { endpoint.stop() }
        guard case let .running(port) = endpoint.state else {
            Issue.record("Endpoint did not start")
            return
        }

        try sendInvite(to: port, supportsTelephoneEvent: true)
        for _ in 0..<20 {
            endpoint.poll()
            if case .incoming = endpoint.callState { break }
            usleep(10_000)
        }
        try endpoint.answerCall()
        endpoint.poll()

        #expect(endpoint.telephoneEventAvailable)
        let result = try endpoint.sendDTMF("#", mode: .telephoneEvent, durationMilliseconds: 160)
        #expect(result.usedMode == .telephoneEvent)
        #expect(!result.usedFallback)
    }

    private func sendInvite(to port: UInt16, supportsTelephoneEvent: Bool = false) throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(descriptor >= 0)
        defer { close(descriptor) }

        let eventPayload = supportsTelephoneEvent ? " 101" : ""
        let eventAttributes = supportsTelephoneEvent
            ? "a=rtpmap:101 telephone-event/8000\r\na=fmtp:101 0-16\r\n"
            : ""
        let sdp = """
        v=0\r
        o=- 1 1 IN IP4 127.0.0.1\r
        s=Test\r
        c=IN IP4 127.0.0.1\r
        t=0 0\r
        m=audio 5000 RTP/AVP 0\(eventPayload)\r
        a=rtpmap:0 PCMU/8000\r
        \(eventAttributes)

        """
        let message = """
        INVITE sip:1001@127.0.0.1 SIP/2.0\r
        Via: SIP/2.0/UDP 127.0.0.1:5099;branch=z9hG4bK-test-invite\r
        Max-Forwards: 70\r
        From: <sip:2002@127.0.0.1>;tag=test-from\r
        To: <sip:1001@127.0.0.1>\r
        Call-ID: test-call@127.0.0.1\r
        CSeq: 1 INVITE\r
        Contact: <sip:2002@127.0.0.1:5099>\r
        Content-Type: application/sdp\r
        Content-Length: \(sdp.utf8.count)\r
        \r
        \(sdp)
        """

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let addressLength = socklen_t(address.sin_len)
        let sent = message.withCString { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    sendto(descriptor, bytes, message.utf8.count, 0, socketAddress, addressLength)
                }
            }
        }
        try #require(sent == message.utf8.count)
    }
}
