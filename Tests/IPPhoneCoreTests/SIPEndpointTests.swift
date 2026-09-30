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
        let logs = AppLogStore()
        let endpoint = SIPEndpoint(logStore: logs)
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
        endpoint.poll()
        #expect(logs.entries.contains { $0.category == "SIP Message" && $0.message.contains("TX request REGISTER") })
        #expect(!logs.exportedText.contains("test-password"))
        #expect(!logs.exportedText.localizedCaseInsensitiveContains("Authorization:"))
    }

    @Test
    func advertisesRoutedAddressInOutgoingSDP() throws {
        let receiver = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(receiver >= 0)
        defer { close(receiver) }
        let serverPort = try bindLoopbackSocket(receiver, family: AF_INET)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        try #require(setsockopt(receiver, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                               socklen_t(MemoryLayout<timeval>.size)) == 0)

        let endpoint = SIPEndpoint()
        try endpoint.start(transport: .udp, serverHost: "127.0.0.1", serverPort: UInt16(serverPort))
        defer { endpoint.stop() }
        #expect(endpoint.boundLocalIPAddress == "127.0.0.1")
        let settings = SIPSettings(
            serverHost: "127.0.0.1",
            serverPort: serverPort,
            userID: "1001",
            phoneNumber: "1001"
        )
        try endpoint.makeCall(destination: "1002", settings: settings, password: "test-password")
        let invite = try receiveMessage(descriptor: receiver)
        #expect(invite.contains("\r\nc=IN IP4 127.0.0.1\r\n"))
    }

    @Test(arguments: [nil, "127.0.0.1"] as [String?])
    func enclosesOutgoingFromAndToURIs(localIPAddress: String?) throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var addressLength = socklen_t(address.sin_len)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, addressLength)
            }
        }
        try #require(bound == 0)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &addressLength)
            }
        }
        try #require(named == 0)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        try #require(setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                               socklen_t(MemoryLayout<timeval>.size)) == 0)

        let endpoint = SIPEndpoint()
        try endpoint.startUDP(port: 0, localIPAddress: localIPAddress)
        defer { endpoint.stop() }
        let settings = SIPSettings(
            serverHost: "127.0.0.1",
            serverPort: Int(address.sin_port.bigEndian),
            userID: "1001",
            phoneNumber: "1001",
            localIPAddress: localIPAddress
        )
        try endpoint.register(settings: settings, password: "test-password")
        let registration = try receiveMessage(descriptor: descriptor)
        #expect(registration.hasPrefix("REGISTER "))
        #expect(registration.contains("\r\nFrom: <sip:1001@127.0.0.1>;tag="))
        #expect(registration.contains("\r\nTo: <sip:1001@127.0.0.1>\r\n"))
        if let localIPAddress, case let .running(port) = endpoint.state {
            #expect(registration.contains("\r\nVia: SIP/2.0/UDP \(localIPAddress):\(port);"))
            #expect(registration.contains("\r\nContact: <sip:1001@\(localIPAddress):\(port);transport=udp>\r\n"))
        }

        try endpoint.makeCall(destination: "1002", settings: settings, password: "test-password")
        let invite = try receiveMessage(descriptor: descriptor)
        #expect(invite.hasPrefix("INVITE sip:1002@127.0.0.1:\(settings.serverPort);transport=udp SIP/2.0\r\n"))
        #expect(invite.contains("\r\nFrom: <sip:1001@127.0.0.1>;tag="))
        #expect(invite.contains("\r\nTo: <sip:1002@127.0.0.1>\r\n"))
        if let localIPAddress, case let .running(port) = endpoint.state {
            #expect(invite.contains("\r\nVia: SIP/2.0/UDP \(localIPAddress):\(port);"))
            #expect(invite.contains("\r\nContact: <sip:1001@\(localIPAddress):\(port);transport=udp>\r\n"))
            #expect(invite.contains("\r\nc=IN IP4 \(localIPAddress)\r\n"))
        }

        guard case let .running(port) = endpoint.state else {
            Issue.record("Endpoint did not start")
            return
        }
        // An INVITE during the outgoing call produces a stateless busy
        // response. Bare incoming URIs must be enclosed in that response too.
        try sendInvite(to: port, senderDescriptor: descriptor, bareURIs: true)
        for _ in 0..<5 {
            endpoint.poll()
            usleep(10_000)
        }
        let response = try receiveMessage(descriptor: descriptor)
        #expect(response.hasPrefix("SIP/2.0 486 "))
        #expect(response.contains("\r\nFrom: <sip:2002@127.0.0.1>;tag=test-from\r\n"))
        #expect(response.contains("\r\nTo: <sip:1001@127.0.0.1>;tag="))
    }

    private func receiveMessage(descriptor: Int32) throws -> String {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let received = buffer.withUnsafeMutableBytes {
            recv(descriptor, $0.baseAddress, $0.count, 0)
        }
        try #require(received > 0)
        return String(decoding: buffer.prefix(received), as: UTF8.self)
    }

    @Test(arguments: [SIPTransport.udp, .tcp], ["127.0.0.1", "::1"])
    func advertisesSelectedAddressInRegistrationAndInvite(transport: SIPTransport, localIP: String) throws {
        let family = localIP.contains(":") ? AF_INET6 : AF_INET
        let receiver = socket(family, transport == .udp ? SOCK_DGRAM : SOCK_STREAM, 0)
        try #require(receiver >= 0)
        defer { close(receiver) }
        let serverPort = try bindLoopbackSocket(receiver, family: family)
        if transport == .tcp {
            try #require(listen(receiver, 1) == 0)
            try #require(fcntl(receiver, F_SETFL, O_NONBLOCK) == 0)
        }

        let endpoint = SIPEndpoint()
        try endpoint.start(transport: transport, localIPAddress: localIP)
        defer { endpoint.stop() }
        let settings = SIPSettings(
            serverHost: localIP,
            serverPort: serverPort,
            transport: transport,
            userID: "1001",
            phoneNumber: "1001",
            sipDomain: "example.test",
            localIPAddress: localIP
        )
        try endpoint.register(settings: settings, password: "test-password")

        var peer = receiver
        if transport == .tcp {
            for _ in 0..<100 {
                endpoint.poll()
                peer = accept(receiver, nil, nil)
                if peer >= 0 { break }
                usleep(1_000)
            }
            try #require(peer >= 0)
            try #require(fcntl(peer, F_SETFL, 0) == 0)
        }
        defer { if transport == .tcp { close(peer) } }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        try #require(setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                               socklen_t(MemoryLayout<timeval>.size)) == 0)
        for _ in 0..<5 { endpoint.poll() }
        let registration = try receiveMessage(descriptor: peer)

        guard case let .running(port) = endpoint.state else {
            Issue.record("Endpoint did not start")
            return
        }
        let headerIP = family == AF_INET6 ? "[\(localIP)]" : localIP
        let contact = "\r\nContact: <sip:1001@\(headerIP):\(port);transport=\(transport.rawValue.lowercased())>\r\n"
        #expect(registration.hasPrefix("REGISTER "))
        #expect(registration.contains("\r\nVia: SIP/2.0/\(transport.rawValue) \(headerIP):"))
        #expect(registration.contains(contact))
        #expect(registration.contains("\r\nFrom: <sip:1001@example.test>;tag="))

        try endpoint.makeCall(destination: "1002", settings: settings, password: "test-password")
        for _ in 0..<5 { endpoint.poll() }
        let invite = try receiveMessage(descriptor: peer)
        #expect(invite.hasPrefix("INVITE "))
        #expect(invite.contains("\r\nVia: SIP/2.0/\(transport.rawValue) \(headerIP):"))
        #expect(invite.contains(contact))
        #expect(invite.contains("\r\nc=IN \(family == AF_INET6 ? "IP6" : "IP4") \(localIP)\r\n"))
        #expect(invite.contains("\r\nFrom: <sip:1001@example.test>;tag="))
    }

    private func bindLoopbackSocket(_ descriptor: Int32, family: Int32) throws -> Int {
        if family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            try #require(inet_pton(AF_INET6, "::1", &address.sin6_addr) == 1)
            var length = socklen_t(address.sin6_len)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
            }
            try #require(bound == 0)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
            }
            try #require(named == 0)
            return Int(address.sin6_port.bigEndian)
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(address.sin_len)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }
        try #require(bound == 0)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        try #require(named == 0)
        return Int(address.sin_port.bigEndian)
    }

    @Test(arguments: ["127.0.0.1", "::1"])
    func startsTLSWithSelectedAddress(localIP: String) throws {
        let endpoint = SIPEndpoint()
        try endpoint.start(transport: .tls, localIPAddress: localIP)
        defer { endpoint.stop() }
        #expect(endpoint.activeLocalIPAddress == localIP)
        #expect(endpoint.activeTransport == .tls)
        guard case let .running(port) = endpoint.state else {
            Issue.record("TLS endpoint did not start")
            return
        }
        #expect(port > 0)
    }

    @Test
    func requiresRestartAfterChangingLocalAddress() throws {
        let endpoint = SIPEndpoint()
        try endpoint.startUDP(localIPAddress: "127.0.0.1")
        defer { endpoint.stop() }
        let settings = SIPSettings(serverHost: "127.0.0.1", userID: "1001", phoneNumber: "1001")
        #expect(throws: SIPEndpointError.self) { try endpoint.register(settings: settings, password: "") }
        #expect(throws: SIPEndpointError.self) { try endpoint.makeCall(destination: "1002", settings: settings, password: "") }
        #expect(throws: SIPEndpointError.self) { try endpoint.startUDP() }
        endpoint.stop()
        #expect(endpoint.activeLocalIPAddress == nil)
        try endpoint.startUDP()
        try endpoint.register(settings: settings, password: "")
    }

    @Test
    func rejectsUnavailableAddressWithoutStartingEndpoint() throws {
        let endpoint = SIPEndpoint()
        let unavailable = "192.0.2.123"
        try #require(!LocalIPAddress.available().contains { $0.address == unavailable })
        #expect(throws: SIPEndpointError.self) { try endpoint.startUDP(localIPAddress: unavailable) }
        #expect(endpoint.state == .stopped)
        try endpoint.startUDP(localIPAddress: "127.0.0.1")
        endpoint.stop()
    }

    @Test
    func usesSelectedAddressInIncomingCallContact() throws {
        let receiver = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(receiver >= 0)
        defer { close(receiver) }
        _ = try bindLoopbackSocket(receiver, family: AF_INET)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        try #require(setsockopt(receiver, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                               socklen_t(MemoryLayout<timeval>.size)) == 0)
        let endpoint = SIPEndpoint()
        try endpoint.startUDP(localIPAddress: "127.0.0.1")
        defer { endpoint.stop() }
        guard case let .running(port) = endpoint.state else {
            Issue.record("Endpoint did not start")
            return
        }
        try sendInvite(to: port, senderDescriptor: receiver, toDomain: "example.test")
        for _ in 0..<5 { endpoint.poll() }
        let ringing = try receiveMessage(descriptor: receiver)
        #expect(ringing.hasPrefix("SIP/2.0 180 "))
        let contact = "\r\nContact: <sip:1001@127.0.0.1:\(port);transport=udp>\r\n"
        #expect(ringing.contains(contact))
        try endpoint.answerCall()
        let answer = try receiveMessage(descriptor: receiver)
        #expect(answer.hasPrefix("SIP/2.0 200 "))
        #expect(answer.contains(contact))
        #expect(answer.contains("\r\nTo: <sip:1001@example.test>;tag="))
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
    func handlesCancelWhileIncomingCallIsRinging() throws {
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

        try sendCancel(to: port)
        for _ in 0..<20 {
            endpoint.poll()
            if case .ended = endpoint.callState { break }
            usleep(10_000)
        }
        guard case .ended = endpoint.callState else {
            Issue.record("Cancelled incoming call did not end")
            return
        }
    }

    @Test
    func receivesAndAnswersIncomingInvite() throws {
        let rtpReceiver = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(rtpReceiver >= 0)
        defer { close(rtpReceiver) }
        let remoteRTPPort = try bindLoopbackSocket(rtpReceiver, family: AF_INET)

        let endpoint = SIPEndpoint()
        try endpoint.start(transport: .udp, port: 0, serverHost: "127.0.0.1")
        defer { endpoint.stop() }
        guard case let .running(port) = endpoint.state else {
            Issue.record("Endpoint did not start")
            return
        }

        try sendInvite(to: port, mediaPort: remoteRTPPort)
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
        var receivedRTP = false
        var packet = [UInt8](repeating: 0, count: 2048)
        for _ in 0..<100 {
            let size = packet.withUnsafeMutableBytes { recv(rtpReceiver, $0.baseAddress, $0.count, MSG_DONTWAIT) }
            if size >= 12, packet[0] >> 6 == 2, packet[1] & 0x7f == 0 {
                receivedRTP = true
                break
            }
            usleep(10_000)
        }
        #expect(receivedRTP)
        usleep(900_000)
        endpoint.poll()
        let packetsBeforeSilence = endpoint.rtpStatistics.transmittedPackets
        usleep(250_000)
        endpoint.poll()
        #expect(endpoint.rtpStatistics.transmittedPackets > packetsBeforeSilence)
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

    private func sendInvite(
        to port: UInt16,
        mediaPort: Int = 5000,
        supportsTelephoneEvent: Bool = false,
        senderDescriptor: Int32? = nil,
        bareURIs: Bool = false,
        toDomain: String = "127.0.0.1"
    ) throws {
        let descriptor = senderDescriptor ?? socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(descriptor >= 0)
        defer { if senderDescriptor == nil { close(descriptor) } }

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
        m=audio \(mediaPort) RTP/AVP 0\(eventPayload)\r
        a=rtpmap:0 PCMU/8000\r
        \(eventAttributes)

        """
        let message = """
        INVITE sip:1001@127.0.0.1 SIP/2.0\r
        Via: SIP/2.0/UDP 127.0.0.1:5099\(senderDescriptor == nil ? "" : ";rport");branch=z9hG4bK-test-invite\r
        Max-Forwards: 70\r
        From: \(bareURIs ? "sip:2002@127.0.0.1" : "<sip:2002@127.0.0.1>");tag=test-from\r
        To: \(bareURIs ? "sip:1001@\(toDomain)" : "<sip:1001@\(toDomain)>")\r
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

    private func sendCancel(to port: UInt16) throws {
        let message = """
        CANCEL sip:1001@127.0.0.1 SIP/2.0\r
        Via: SIP/2.0/UDP 127.0.0.1:5099;branch=z9hG4bK-test-invite\r
        Max-Forwards: 70\r
        From: <sip:2002@127.0.0.1>;tag=test-from\r
        To: <sip:1001@127.0.0.1>\r
        Call-ID: test-call@127.0.0.1\r
        CSeq: 1 CANCEL\r
        Content-Length: 0\r
        \r

        """
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
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
