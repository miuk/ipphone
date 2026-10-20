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

    @Test(arguments: ["", ";user=phone;transport=udp;ttl=3;maddr=127.0.0.1;lr;x-test=value"],
          ["2002", "2002;extension"])
    func usesExplicitRequestURIAndRemovesToURIParameters(parameters: String, user: String) throws {
        let receiver = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(receiver >= 0)
        defer { close(receiver) }
        let port = try bindLoopbackSocket(receiver, family: AF_INET)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        try #require(setsockopt(receiver, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                               socklen_t(MemoryLayout<timeval>.size)) == 0)

        let endpoint = SIPEndpoint()
        try endpoint.startUDP(port: 0)
        defer { endpoint.stop() }
        let settings = SIPSettings(
            serverHost: "127.0.0.1",
            serverPort: 9,
            userID: "1001",
            phoneNumber: "1001",
            sipDomain: "example.test"
        )
        let address = "sip:\(user)@127.0.0.1:\(port)"
        let destination = address + parameters
        try endpoint.makeCall(destination: destination, settings: settings, password: "test-password")
        let invite = try receiveMessage(descriptor: receiver)
        #expect(invite.hasPrefix("INVITE \(destination) SIP/2.0\r\n"))
        #expect(invite.contains("\r\nTo: <\(address)>\r\n"))
        #expect(invite.contains("\r\nFrom: <sip:1001@example.test>;tag="))
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

    @Test(arguments: ["0", "112", "112 0", "0 112"])
    func receivesAndAnswersIncomingInvite(audioPayloads: String) throws {
        let expectedCodec = audioPayloads.hasPrefix("112") ? "opus/48000" : "PCMU/8000"
        let expectedPayload: UInt8 = audioPayloads.hasPrefix("112") ? 112 : 0
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

        try sendInvite(to: port, mediaPort: remoteRTPPort, audioPayloads: audioPayloads)
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
        guard endpoint.mediaState == .active(codec: expectedCodec) else {
            Issue.record("Expected \(expectedCodec), got \(endpoint.mediaState)")
            return
        }
        var receivedPacketSize = 0
        var packet = [UInt8](repeating: 0, count: 2048)
        for _ in 0..<100 {
            let size = packet.withUnsafeMutableBytes { recv(rtpReceiver, $0.baseAddress, $0.count, MSG_DONTWAIT) }
            if size >= 12, packet[0] >> 6 == 2, packet[1] & 0x7f == expectedPayload {
                receivedPacketSize = size
                break
            }
            usleep(10_000)
        }
        try #require(receivedPacketSize >= 12)
        // Feed valid encoded packets back as a distinct remote RTP source.
        // This exercises the Opus decoder as well as the encoder.
        var remotePacket = Array(packet.prefix(receivedPacketSize))
        remotePacket[8...11] = [0x12, 0x34, 0x56, 0x78]
        for sequence in 0..<20 {
            remotePacket[2] = 0
            remotePacket[3] = UInt8(sequence)
            let timestamp = UInt32(sequence * (expectedPayload == 112 ? 960 : 160))
            for byte in 0..<4 { remotePacket[4 + byte] = UInt8(truncatingIfNeeded: timestamp >> (24 - byte * 8)) }
            try sendUDP(remotePacket, descriptor: rtpReceiver, to: 4_000)
            usleep(20_000)
        }
        endpoint.poll()
        #expect(endpoint.rtpStatistics.receivedPackets > 0)
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

    @Test(arguments: ["0", "112", "112 0", "0 112"])
    func sendsNegotiatedTelephoneEvent(audioPayloads: String) throws {
        let receiver = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        let rtpReceiver = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(receiver >= 0 && rtpReceiver >= 0)
        defer { close(receiver); close(rtpReceiver) }
        _ = try bindLoopbackSocket(receiver, family: AF_INET)
        let remoteRTPPort = try bindLoopbackSocket(rtpReceiver, family: AF_INET)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        try #require(setsockopt(receiver, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                               socklen_t(MemoryLayout<timeval>.size)) == 0)
        let opus = audioPayloads.hasPrefix("112")
        let clockRate = opus ? 48_000 : 8_000
        let eventPayload: UInt8 = opus ? 103 : 101
        let endpoint = SIPEndpoint()
        try endpoint.startUDP(port: 0)
        defer { endpoint.stop() }
        guard case let .running(port) = endpoint.state else {
            Issue.record("Endpoint did not start")
            return
        }

        try sendInvite(to: port, mediaPort: remoteRTPPort, supportsTelephoneEvent: true,
                       senderDescriptor: receiver, audioPayloads: audioPayloads)
        for _ in 0..<20 {
            endpoint.poll()
            if case .incoming = endpoint.callState { break }
            usleep(10_000)
        }
        try endpoint.answerCall()
        endpoint.poll()

        let ringing = try receiveMessage(descriptor: receiver)
        #expect(ringing.hasPrefix("SIP/2.0 180"))
        let answer = try receiveMessage(descriptor: receiver)
        #expect(answer.hasPrefix("SIP/2.0 200"))
        #expect(answer.contains("a=rtpmap:\(eventPayload) telephone-event/\(clockRate)\r\n"))
        #expect(!answer.contains("telephone-event/\(opus ? 8_000 : 48_000)"))
        #expect(endpoint.telephoneEventAvailable)
        let result = try endpoint.sendDTMF("#", mode: .telephoneEvent, durationMilliseconds: 160)
        #expect(result.usedMode == .telephoneEvent)
        #expect(!result.usedFallback)
        var packet = [UInt8](repeating: 0, count: 2048)
        var endDuration: Int?
        for _ in 0..<100 {
            let count = packet.withUnsafeMutableBytes { recv(rtpReceiver, $0.baseAddress, $0.count, MSG_DONTWAIT) }
            if count >= 16 && packet[1] & 0x7f == eventPayload && packet[13] & 0x80 != 0 {
                #expect(packet[12] == 11) // '#'
                endDuration = Int(packet[14]) * 256 + Int(packet[15])
                break
            }
            usleep(10_000)
        }
        let duration = try #require(endDuration)
        #expect(duration >= clockRate * 160 / 1000)
        #expect(duration <= clockRate * 180 / 1000)
    }

    @Test(arguments: ["112", "0"])
    func omitsTelephoneEventWhenOfferedClockDoesNotMatchAudio(audioPayloads: String) throws {
        let receiver = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(receiver >= 0)
        defer { close(receiver) }
        _ = try bindLoopbackSocket(receiver, family: AF_INET)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        try #require(setsockopt(receiver, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                               socklen_t(MemoryLayout<timeval>.size)) == 0)
        let endpoint = SIPEndpoint()
        try endpoint.start(transport: .udp, serverHost: "127.0.0.1")
        defer { endpoint.stop() }
        guard case let .running(port) = endpoint.state else { return }
        try sendInvite(to: port, supportsTelephoneEvent: true, senderDescriptor: receiver, audioPayloads: audioPayloads,
                       eventClockRates: audioPayloads == "112" ? [8_000] : [48_000])
        for _ in 0..<20 {
            endpoint.poll()
            if case .incoming = endpoint.callState { break }
            usleep(10_000)
        }
        try endpoint.answerCall()
        endpoint.poll()
        _ = try receiveMessage(descriptor: receiver) // 180 Ringing
        let answer = try receiveMessage(descriptor: receiver)
        #expect(answer.hasPrefix("SIP/2.0 200"))
        #expect(!answer.contains("telephone-event/"))
        #expect(!endpoint.telephoneEventAvailable)
        let result = try endpoint.sendDTMF("5", mode: .telephoneEvent, durationMilliseconds: 100)
        #expect(result.usedFallback)
    }

    @Test(arguments: ["opus", "PCMU", "opus PCMU", "PCMU opus"], DTMFMode.allCases)
    func offersOnlyEnabledCodecsInConfiguredOrder(order: String, dtmfMode: DTMFMode) throws {
        let receiver = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(receiver >= 0)
        defer { close(receiver) }
        let serverPort = try bindLoopbackSocket(receiver, family: AF_INET)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        try #require(setsockopt(receiver, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                               socklen_t(MemoryLayout<timeval>.size)) == 0)
        var codecs = AudioCodecSettings()
        codecs.offerOpus = order.contains("opus")
        codecs.offerPCMU = order.contains("PCMU")
        codecs.preferredOfferCodec = order.hasPrefix("opus") ? .opus : .pcmu
        // Incoming capabilities must not affect the outgoing offer.
        codecs.acceptOpus = !codecs.offerOpus || codecs.offerPCMU
        codecs.acceptPCMU = !codecs.offerPCMU || codecs.offerOpus
        let endpoint = SIPEndpoint()
        try endpoint.start(transport: .udp, serverHost: "127.0.0.1")
        defer { endpoint.stop() }
        let settings = SIPSettings(codecs: codecs, serverHost: "127.0.0.1",
                                   serverPort: serverPort, userID: "1001", phoneNumber: "1001",
                                   dtmfMode: dtmfMode)
        try endpoint.makeCall(destination: "1002", settings: settings, password: "test")
        let invite = try receiveMessage(descriptor: receiver)
        let payloads = order.replacingOccurrences(of: "opus", with: "111")
            .replacingOccurrences(of: "PCMU", with: "0")
        let opusEvent = dtmfMode == .telephoneEvent && codecs.offerOpus
        let pcmuEvent = dtmfMode == .telephoneEvent && codecs.offerPCMU
        let eventPayloads = (opusEvent ? " 102" : "") + (pcmuEvent ? " 101" : "")
        #expect(invite.contains(" RTP/AVP \(payloads)\(eventPayloads)\r\n"))
        #expect(invite.contains("a=rtpmap:102 telephone-event/48000\r\n") == opusEvent)
        #expect(invite.contains("a=fmtp:102 0-16\r\n") == opusEvent)
        #expect(invite.contains("a=rtpmap:101 telephone-event/8000\r\n") == pcmuEvent)
        #expect(invite.contains("a=fmtp:101 0-16\r\n") == pcmuEvent)
        #expect(invite.contains("telephone-event/") == (dtmfMode == .telephoneEvent))
        #expect(invite.contains("a=rtpmap:111 opus/48000/2") == codecs.offerOpus)
        #expect(invite.contains("a=rtpmap:0 PCMU/8000") == codecs.offerPCMU)
    }

    @Test(arguments: [AudioCodec.opus, .pcmu])
    func incomingCallSkipsDisabledPreferredCodec(enabled: AudioCodec) throws {
        var codecs = AudioCodecSettings()
        codecs.acceptOpus = enabled == .opus
        codecs.acceptPCMU = enabled == .pcmu
        codecs.offerOpus = enabled != .opus
        codecs.offerPCMU = enabled != .pcmu
        let endpoint = SIPEndpoint()
        try endpoint.start(transport: .udp, serverHost: "127.0.0.1", codecs: codecs)
        defer { endpoint.stop() }
        guard case let .running(port) = endpoint.state else { return }
        try sendInvite(to: port, audioPayloads: enabled == .opus ? "0 112" : "112 0")
        for _ in 0..<20 {
            endpoint.poll()
            if case .incoming = endpoint.callState { break }
            usleep(10_000)
        }
        try endpoint.answerCall()
        endpoint.poll()
        #expect(endpoint.mediaState == .active(codec: enabled == .opus ? "opus/48000" : "PCMU/8000"))
    }

    @Test
    func rejectsOfferWithoutEnabledCodec() throws {
        var codecs = AudioCodecSettings()
        codecs.acceptPCMU = false
        let logs = AppLogStore()
        let endpoint = SIPEndpoint(logStore: logs)
        try endpoint.start(transport: .udp, serverHost: "127.0.0.1", codecs: codecs)
        defer { endpoint.stop() }
        guard case let .running(port) = endpoint.state else { return }
        try sendInvite(to: port)
        for _ in 0..<20 { endpoint.poll(); usleep(10_000) }
        if case .incoming = endpoint.callState {
            try endpoint.answerCall()
            endpoint.poll()
        }
        #expect(logs.entries.contains { $0.message.contains("TX response 488") })
        #expect(endpoint.mediaState != .active(codec: "PCMU/8000"))
    }

    @Test(arguments: [AudioCodec.opus, .pcmu], [0, 8_000, 48_000])
    func startsOutgoingMediaUsingAnsweredCodec(codec: AudioCodec, eventClockRate: Int) throws {
        let receiver = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(receiver >= 0)
        let rtpReceiver = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(rtpReceiver >= 0)
        defer { close(receiver); close(rtpReceiver) }
        let remoteRTPPort = try bindLoopbackSocket(rtpReceiver, family: AF_INET)
        let serverPort = try bindLoopbackSocket(receiver, family: AF_INET)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        try #require(setsockopt(receiver, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                               socklen_t(MemoryLayout<timeval>.size)) == 0)
        let endpoint = SIPEndpoint()
        try endpoint.start(transport: .udp, serverHost: "127.0.0.1")
        defer { endpoint.stop() }
        guard case let .running(port) = endpoint.state else { return }
        let settings = SIPSettings(serverHost: "127.0.0.1", serverPort: serverPort,
                                   userID: "1001", phoneNumber: "1001")
        try endpoint.makeCall(destination: "1002", settings: settings, password: "test")
        let invite = try receiveMessage(descriptor: receiver)
        let headers = invite.components(separatedBy: "\r\n")
        func header(_ name: String) throws -> String {
            try #require(headers.first { $0.lowercased().hasPrefix(name.lowercased() + ":") })
        }
        let payload = codec == .opus ? "111" : "0"
        let mapping = codec == .opus ? "opus/48000/2" : "PCMU/8000"
        let eventPayload = eventClockRate == 48_000 ? 102 : 101
        let eventFormats = eventClockRate == 0 ? "" : " \(eventPayload)"
        let eventAttributes = eventClockRate == 0 ? "" : "a=rtpmap:\(eventPayload) telephone-event/\(eventClockRate)\r\na=fmtp:\(eventPayload) 0-16\r\n"
        let sdp = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=Test\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio \(remoteRTPPort) RTP/AVP \(payload)\(eventFormats)\r\na=rtpmap:\(payload) \(mapping)\r\n\(eventAttributes)"
        let response = try ["SIP/2.0 200 OK", header("Via"), header("From"),
                            header("To") + ";tag=test-answer", header("Call-ID"), header("CSeq"),
                            "Contact: <sip:1002@127.0.0.1:\(serverPort)>",
                            "Content-Type: application/sdp", "Content-Length: \(sdp.utf8.count)",
                            "", sdp].joined(separator: "\r\n")
        try sendUDP(Array(response.utf8), descriptor: receiver, to: port)
        for _ in 0..<20 {
            endpoint.poll()
            if case .active = endpoint.mediaState { break }
            usleep(10_000)
        }
        #expect(endpoint.mediaState == .active(codec: codec == .opus ? "opus/48000" : "PCMU/8000"))
        let matchingClock = eventClockRate == (codec == .opus ? 48_000 : 8_000)
        let accepts8kEventForOpus = codec == .opus && eventClockRate == 8_000
        let usesTelephoneEvent = matchingClock || accepts8kEventForOpus
        #expect(endpoint.telephoneEventAvailable == usesTelephoneEvent)
        let durations = accepts8kEventForOpus ? [100, 1_600] : [100]
        var previousEventTimestamp: UInt32?
        for (index, durationMilliseconds) in durations.enumerated() {
            let digit: Character = index == 0 ? "5" : "6"
            let result = try endpoint.sendDTMF(digit, mode: .telephoneEvent,
                                             durationMilliseconds: UInt32(durationMilliseconds))
            #expect(result.usedFallback == !usesTelephoneEvent)
            guard usesTelephoneEvent else { continue }
            var packet = [UInt8](repeating: 0, count: 2048)
            var endDuration: Int?
            var eventTimestamp: UInt32?
            var firstDuration: Int?
            for _ in 0..<400 {
                let count = packet.withUnsafeMutableBytes { recv(rtpReceiver, $0.baseAddress, $0.count, MSG_DONTWAIT) }
                if count >= 16 && packet[1] & 0x7f == eventPayload && packet[12] == (index == 0 ? 5 : 6) {
                    let timestamp = (UInt32(packet[4]) << 24) | (UInt32(packet[5]) << 16)
                        | (UInt32(packet[6]) << 8) | UInt32(packet[7])
                    if let eventTimestamp { #expect(timestamp == eventTimestamp) }
                    eventTimestamp = timestamp
                    let duration = Int(packet[14]) * 256 + Int(packet[15])
                    if firstDuration == nil { firstDuration = duration }
                    if packet[13] & 0x80 != 0 {
                        endDuration = duration
                        break
                    }
                }
                usleep(10_000)
            }
            let duration = try #require(endDuration)
            #expect(duration == eventClockRate * durationMilliseconds / 1000)
            #expect(try #require(firstDuration) <= eventClockRate * 20 / 1000)
            let timestamp = try #require(eventTimestamp)
            if let previousEventTimestamp {
                let delta = timestamp &- previousEventTimestamp
                #expect(delta >= UInt32(eventClockRate * 100 / 1000))
                #expect(delta < UInt32(eventClockRate))
            }
            previousEventTimestamp = timestamp
        }
    }

    private func sendUDP(_ bytes: [UInt8], descriptor: Int32, to port: UInt16) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let length = socklen_t(address.sin_len)
        let sent = bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, buffer.baseAddress, buffer.count, 0, $0, length)
                }
            }
        }
        try #require(sent == bytes.count)
    }

    private func sendInvite(
        to port: UInt16,
        mediaPort: Int = 5000,
        supportsTelephoneEvent: Bool = false,
        senderDescriptor: Int32? = nil,
        bareURIs: Bool = false,
        toDomain: String = "127.0.0.1",
        audioPayloads: String = "0",
        eventClockRates: [Int]? = nil
    ) throws {
        let descriptor = senderDescriptor ?? socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(descriptor >= 0)
        defer { if senderDescriptor == nil { close(descriptor) } }

        let rates = supportsTelephoneEvent ? (eventClockRates ??
            ((audioPayloads.contains("0") ? [8_000] : []) + (audioPayloads.contains("112") ? [48_000] : []))) : []
        let eventPayload = rates.map { $0 == 48_000 ? " 103" : " 101" }.joined()
        let eventAttributes = rates.map { rate in
            let payload = rate == 48_000 ? 103 : 101
            return "a=rtpmap:\(payload) telephone-event/\(rate)\r\na=fmtp:\(payload) 0-16\r\n"
        }.joined()
        let sdp = """
        v=0\r
        o=- 1 1 IN IP4 127.0.0.1\r
        s=Test\r
        c=IN IP4 127.0.0.1\r
        t=0 0\r
        m=audio \(mediaPort) RTP/AVP \(audioPayloads)\(eventPayload)\r
        a=rtpmap:0 PCMU/8000\r
        a=rtpmap:112 opus/48000/2\r
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
