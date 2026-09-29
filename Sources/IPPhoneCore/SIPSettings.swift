import Foundation

public enum SIPTransport: String, Codable, CaseIterable, Identifiable, Sendable {
    case udp = "UDP"
    case tcp = "TCP"
    case tls = "TLS"

    public var id: Self { self }
    public var defaultPort: Int { self == .tls ? 5061 : 5060 }
}

public enum DTMFMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case telephoneEvent = "telephone-event"
    case inBand = "in-band"

    public var id: Self { self }
}

public enum TLSURIScheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case sip = "sip"
    case sips = "sips"

    public var id: Self { self }
}

public struct SIPSettings: Codable, Equatable, Sendable {
    public var serverHost: String
    public var serverPort: Int
    public var transport: SIPTransport
    public var userID: String
    public var phoneNumber: String
    public var sipDomain: String
    public var displayName: String
    public var dtmfMode: DTMFMode
    public var tlsURIScheme: TLSURIScheme
    public var allowSelfSignedCertificate: Bool
    public var localSIPPort: Int
    public var registrationExpiration: Int
    public var rtpPortStart: Int
    public var rtpPortEnd: Int
    public var outboundProxy: String

    public init(
        serverHost: String = "",
        serverPort: Int = 5060,
        transport: SIPTransport = .udp,
        userID: String = "",
        phoneNumber: String = "",
        sipDomain: String = "",
        displayName: String = "",
        dtmfMode: DTMFMode = .telephoneEvent,
        tlsURIScheme: TLSURIScheme = .sip,
        allowSelfSignedCertificate: Bool = true,
        localSIPPort: Int = 0,
        registrationExpiration: Int = 300,
        rtpPortStart: Int = 4_000,
        rtpPortEnd: Int = 4_999,
        outboundProxy: String = ""
    ) {
        self.serverHost = serverHost
        self.serverPort = serverPort
        self.transport = transport
        self.userID = userID
        self.phoneNumber = phoneNumber
        self.sipDomain = sipDomain
        self.displayName = displayName
        self.dtmfMode = dtmfMode
        self.tlsURIScheme = tlsURIScheme
        self.allowSelfSignedCertificate = allowSelfSignedCertificate
        self.localSIPPort = localSIPPort
        self.registrationExpiration = registrationExpiration
        self.rtpPortStart = rtpPortStart
        self.rtpPortEnd = rtpPortEnd
        self.outboundProxy = outboundProxy
    }

    public var effectiveSIPDomain: String {
        let domain = sipDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        return domain.isEmpty
            ? serverHost.trimmingCharacters(in: .whitespacesAndNewlines)
            : domain
    }

    public var addressOfRecord: String? {
        guard !phoneNumber.isEmpty, !effectiveSIPDomain.isEmpty else { return nil }
        return "sip:\(normalizedNumber(phoneNumber))@\(formattedHost(effectiveSIPDomain))"
    }

    public var registrarURI: String? {
        let host = serverHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, (1...65_535).contains(serverPort) else { return nil }
        return "sip:\(formattedHost(host)):\(serverPort);transport=\(transport.rawValue.lowercased())"
    }

    public func destinationURI(for input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("sip:") || trimmed.lowercased().hasPrefix("sips:") {
            guard Self.looksLikeCompleteSIPURI(trimmed) else {
                throw SIPSettingsValidationError.invalidDestinationURI
            }
            return trimmed
        }

        let number = normalizedNumber(trimmed)
        guard Self.isValidPhoneNumber(number), !effectiveSIPDomain.isEmpty else {
            throw SIPSettingsValidationError.invalidDestinationURI
        }

        let scheme = transport == .tls ? tlsURIScheme.rawValue : "sip"
        var uri = "\(scheme):\(number)@\(formattedHost(effectiveSIPDomain))"
        if transport == .tls, tlsURIScheme == .sip {
            uri += ";transport=tls"
        }
        return uri
    }

    public func validationIssues() -> [SIPSettingsValidationIssue] {
        var issues: [SIPSettingsValidationIssue] = []
        if serverHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(field: .serverHost, message: "SIPサーバーを入力してください。"))
        }
        if !(1...65_535).contains(serverPort) {
            issues.append(.init(field: .serverPort, message: "SIPポートは1～65535で指定してください。"))
        }
        if !(0...65_535).contains(localSIPPort) {
            issues.append(.init(field: .localSIPPort, message: "ローカルSIPポートは0～65535で指定してください。"))
        }
        if userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(field: .userID, message: "user IDを入力してください。"))
        }
        let number = normalizedNumber(phoneNumber)
        if !Self.isValidPhoneNumber(number) {
            issues.append(.init(field: .phoneNumber, message: "自電話番号の形式が正しくありません。"))
        }
        if effectiveSIPDomain.isEmpty {
            issues.append(.init(field: .sipDomain, message: "SIPドメインを指定できません。"))
        }
        if !(60...86_400).contains(registrationExpiration) {
            issues.append(.init(field: .registrationExpiration, message: "REGISTER有効期限は60～86400秒で指定してください。"))
        }
        if !(1_024...65_535).contains(rtpPortStart)
            || !(1_024...65_535).contains(rtpPortEnd)
            || rtpPortStart > rtpPortEnd
        {
            issues.append(.init(field: .rtpPortRange, message: "RTPポート範囲が正しくありません。"))
        }
        return issues
    }

    public mutating func selectTransport(_ newTransport: SIPTransport) {
        let oldDefault = transport.defaultPort
        transport = newTransport
        if serverPort == oldDefault {
            serverPort = newTransport.defaultPort
        }
    }

    private func normalizedNumber(_ value: String) -> String {
        value.filter { !" -()".contains($0) }
    }

    private func formattedHost(_ value: String) -> String {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.contains(":"), !host.hasPrefix("[") { return "[\(host)]" }
        return host
    }

    private static func isValidPhoneNumber(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let remainder = value.hasPrefix("+") ? value.dropFirst() : value[...]
        return !remainder.isEmpty && remainder.allSatisfy { $0.isNumber || $0 == "*" || $0 == "#" }
    }

    private static func looksLikeCompleteSIPURI(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":") else { return false }
        let body = value[value.index(after: colon)...]
        guard let at = body.firstIndex(of: "@") else { return false }
        return at != body.startIndex && body.index(after: at) != body.endIndex
    }
}

public enum SIPSettingsField: String, Sendable {
    case serverHost
    case serverPort
    case localSIPPort
    case userID
    case phoneNumber
    case sipDomain
    case registrationExpiration
    case rtpPortRange
}

public struct SIPSettingsValidationIssue: Equatable, Sendable {
    public let field: SIPSettingsField
    public let message: String

    public init(field: SIPSettingsField, message: String) {
        self.field = field
        self.message = message
    }
}

public enum SIPSettingsValidationError: LocalizedError, Equatable {
    case invalidDestinationURI

    public var errorDescription: String? { "発信先のSIP URIが正しくありません。" }
}
