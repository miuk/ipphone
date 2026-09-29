import CPJSIPBridge
import Foundation

public enum SIPEndpointState: Equatable, Sendable {
    case stopped
    case running(localPort: UInt16)
    case failed(message: String)
}

public enum SIPRegistrationState: Equatable, Sendable {
    case unregistered
    case registering
    case registered(expiration: UInt32)
    case unregistering
    case failed(statusCode: Int, message: String)
}

public enum SIPCallState: Equatable, Sendable {
    case idle
    case outgoing(remoteURI: String)
    case ringing(remoteURI: String)
    case incoming(remoteURI: String)
    case connected(remoteURI: String)
    case disconnecting
    case ended(statusCode: Int, message: String)
    case failed(statusCode: Int, message: String)
}

public enum SIPMediaState: Equatable, Sendable {
    case idle
    case starting
    case active(codec: String)
    case failed(message: String)
}

public struct RTPStatistics: Equatable, Sendable {
    public var transmittedPackets: UInt32 = 0
    public var receivedPackets: UInt32 = 0
    public var lostPackets: UInt32 = 0
    public var jitterMicroseconds: UInt32 = 0

    public init() {}
}

public struct DTMFSendResult: Equatable, Sendable {
    public let requestedMode: DTMFMode
    public let usedMode: DTMFMode

    public var usedFallback: Bool { requestedMode != usedMode }
}

public enum SIPEndpointError: LocalizedError, Equatable {
    case allocationFailed
    case startupFailed(String)
    case registrationFailed(String)
    case callFailed(String)

    public var errorDescription: String? {
        switch self {
        case .allocationFailed:
            "PJSIP endpoint allocation failed."
        case let .startupFailed(message):
            message
        case let .registrationFailed(message):
            message
        case let .callFailed(message):
            message
        }
    }
}

private final class PJSIPHandle: @unchecked Sendable {
    let rawValue: OpaquePointer

    init(_ rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    deinit {
        ip_pjsip_endpoint_destroy(rawValue)
    }
}

/// Owns the process-wide PJSIP endpoint. The application creates one instance
/// and uses it as the root of signaling services.
@MainActor
public final class SIPEndpoint: ObservableObject {
    @Published public private(set) var state: SIPEndpointState = .stopped
    @Published public private(set) var registrationState: SIPRegistrationState = .unregistered
    @Published public private(set) var callState: SIPCallState = .idle
    @Published public private(set) var mediaState: SIPMediaState = .idle
    @Published public private(set) var isMuted = false
    @Published public private(set) var rtpStatistics = RTPStatistics()
    @Published public private(set) var telephoneEventAvailable = false
    @Published public private(set) var activeTransport: SIPTransport?

    public let pjsipVersion: String

    private var handle: PJSIPHandle?
    private weak var logStore: AppLogStore?

    public init(logStore: AppLogStore? = nil) {
        self.logStore = logStore
        pjsipVersion = String(cString: ip_pjsip_version())
        logStore?.append(.info, category: "SIP", "PJSIP \(pjsipVersion) loaded")
    }

    public func startUDP(
        port: UInt16 = 0,
        rtpPort: UInt16 = 4_000,
        audioInputDevice: Int32 = -1,
        audioOutputDevice: Int32 = -1
    ) throws {
        try start(
            transport: .udp,
            port: port,
            rtpPort: rtpPort,
            audioInputDevice: audioInputDevice,
            audioOutputDevice: audioOutputDevice,
            allowSelfSignedCertificate: true
        )
    }

    public func start(
        transport: SIPTransport,
        port: UInt16 = 0,
        rtpPort: UInt16 = 4_000,
        audioInputDevice: Int32 = -1,
        audioOutputDevice: Int32 = -1,
        allowSelfSignedCertificate: Bool = true
    ) throws {
        guard handle == nil else {
            return
        }
        guard let newHandle = ip_pjsip_endpoint_create() else {
            state = .failed(message: SIPEndpointError.allocationFailed.localizedDescription)
            logStore?.append(.error, category: "SIP", SIPEndpointError.allocationFailed.localizedDescription)
            throw SIPEndpointError.allocationFailed
        }

        var errorBuffer = [CChar](repeating: 0, count: 512)
        let bridgeTransport: IPPJSIPTransport = switch transport {
        case .udp: IP_PJSIP_TRANSPORT_UDP
        case .tcp: IP_PJSIP_TRANSPORT_TCP
        case .tls: IP_PJSIP_TRANSPORT_TLS
        }
        let started = ip_pjsip_endpoint_start(
            newHandle,
            bridgeTransport,
            port,
            rtpPort,
            audioInputDevice,
            audioOutputDevice,
            allowSelfSignedCertificate,
            &errorBuffer,
            Int32(errorBuffer.count)
        )

        guard started else {
            let messageBytes = errorBuffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
            let message = String(decoding: messageBytes, as: UTF8.self)
            ip_pjsip_endpoint_destroy(newHandle)
            state = .failed(message: message)
            logStore?.append(.error, category: "SIP", message)
            throw SIPEndpointError.startupFailed(message)
        }

        handle = PJSIPHandle(newHandle)
        let boundPort = ip_pjsip_endpoint_bound_port(newHandle)
        state = .running(localPort: boundPort)
        activeTransport = transport
        let certificatePolicy = transport == .tls
            ? allowSelfSignedCertificate
                ? ", server certificate verification disabled"
                : ", server certificate verification enabled"
            : ""
        logStore?.append(
            .info,
            category: "SIP",
            "\(transport.rawValue) endpoint started on local port \(boundPort)\(certificatePolicy)"
        )
    }

    public func register(settings: SIPSettings, password: String) throws {
        guard let handle else {
            throw SIPEndpointError.registrationFailed("SIP endpoint is not running.")
        }
        guard activeTransport == settings.transport else {
            throw SIPEndpointError.registrationFailed("Stop and restart the endpoint after changing SIP transport.")
        }
        guard settings.validationIssues().isEmpty else {
            throw SIPEndpointError.registrationFailed("SIP settings are invalid.")
        }
        guard let registrarURI = settings.registrarURI,
              let addressOfRecord = settings.addressOfRecord
        else {
            throw SIPEndpointError.registrationFailed("SIP server or address of record is invalid.")
        }

        var errorBuffer = [CChar](repeating: 0, count: 512)
        let started = registrarURI.withCString { registrar in
            addressOfRecord.withCString { aor in
                settings.userID.withCString { userID in
                    password.withCString { password in
                        ip_pjsip_endpoint_register(
                            handle.rawValue,
                            registrar,
                            aor,
                            userID,
                            password,
                            UInt32(settings.registrationExpiration),
                            &errorBuffer,
                            Int32(errorBuffer.count)
                        )
                    }
                }
            }
        }
        guard started else {
            let message = Self.decode(errorBuffer)
            registrationState = .failed(statusCode: 0, message: message)
            logStore?.append(.error, category: "REGISTER", message)
            throw SIPEndpointError.registrationFailed(message)
        }

        registrationState = .registering
        logStore?.append(.info, category: "REGISTER", "REGISTER sent to \(registrarURI) for \(addressOfRecord)")
    }

    public func unregister() throws {
        guard let handle else {
            throw SIPEndpointError.registrationFailed("SIP endpoint is not running.")
        }
        var errorBuffer = [CChar](repeating: 0, count: 512)
        guard ip_pjsip_endpoint_unregister(handle.rawValue, &errorBuffer, Int32(errorBuffer.count)) else {
            let message = Self.decode(errorBuffer)
            logStore?.append(.error, category: "REGISTER", message)
            throw SIPEndpointError.registrationFailed(message)
        }
        registrationState = .unregistering
        logStore?.append(.info, category: "REGISTER", "Unregister sent")
    }

    public func makeCall(
        destination: String,
        settings: SIPSettings,
        password: String
    ) throws {
        guard let handle else {
            throw SIPEndpointError.callFailed("SIP endpoint is not running.")
        }
        guard activeTransport == settings.transport else {
            throw SIPEndpointError.callFailed("Stop and restart the endpoint after changing SIP transport.")
        }
        guard settings.validationIssues().isEmpty,
              let localURI = settings.addressOfRecord,
              let targetURI = settings.registrarURI,
              let rtpPort = UInt16(exactly: settings.rtpPortStart)
        else {
            throw SIPEndpointError.callFailed("SIP settings are invalid.")
        }
        let destinationURI = try settings.destinationURI(for: destination)
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let started = localURI.withCString { localURI in
            destinationURI.withCString { destinationURI in
                targetURI.withCString { targetURI in
                    settings.userID.withCString { userID in
                        password.withCString { password in
                            ip_pjsip_endpoint_make_call(
                                handle.rawValue,
                                localURI,
                                destinationURI,
                                targetURI,
                                userID,
                                password,
                                rtpPort,
                                &errorBuffer,
                                Int32(errorBuffer.count)
                            )
                        }
                    }
                }
            }
        }
        guard started else {
            let message = Self.decode(errorBuffer)
            callState = .failed(statusCode: 0, message: message)
            logStore?.append(.error, category: "Call", message)
            throw SIPEndpointError.callFailed(message)
        }
        callState = .outgoing(remoteURI: destinationURI)
        logStore?.append(.info, category: "Call", "INVITE sent to \(destinationURI)")
    }

    public func answerCall() throws {
        guard let handle else { throw SIPEndpointError.callFailed("SIP endpoint is not running.") }
        var errorBuffer = [CChar](repeating: 0, count: 512)
        guard ip_pjsip_endpoint_answer_call(handle.rawValue, &errorBuffer, Int32(errorBuffer.count)) else {
            let message = Self.decode(errorBuffer)
            logStore?.append(.error, category: "Call", message)
            throw SIPEndpointError.callFailed(message)
        }
        let remoteURI = String(cString: ip_pjsip_endpoint_remote_uri(handle.rawValue))
        callState = .connected(remoteURI: remoteURI)
        logStore?.append(.info, category: "Call", "Incoming call answered")
    }

    public func endCall(statusCode: Int = 603) throws {
        guard let handle else { throw SIPEndpointError.callFailed("SIP endpoint is not running.") }
        var errorBuffer = [CChar](repeating: 0, count: 512)
        guard ip_pjsip_endpoint_end_call(
            handle.rawValue,
            Int32(statusCode),
            &errorBuffer,
            Int32(errorBuffer.count)
        ) else {
            let message = Self.decode(errorBuffer)
            logStore?.append(.error, category: "Call", message)
            throw SIPEndpointError.callFailed(message)
        }
        updateCallState(handle: handle.rawValue)
        logStore?.append(.info, category: "Call", "Call termination initiated")
    }

    public func setMuted(_ muted: Bool) {
        guard let handle, ip_pjsip_endpoint_set_muted(handle.rawValue, muted) else { return }
        isMuted = muted
        logStore?.append(.info, category: "Media", muted ? "Microphone muted" : "Microphone unmuted")
    }

    @discardableResult
    public func sendDTMF(
        _ digit: Character,
        mode: DTMFMode,
        durationMilliseconds: UInt32 = 160
    ) throws -> DTMFSendResult {
        guard let handle else { throw SIPEndpointError.callFailed("SIP endpoint is not running.") }
        guard digit.isASCII, let ascii = digit.asciiValue else {
            throw SIPEndpointError.callFailed("Invalid DTMF digit.")
        }
        var usedMode = IP_PJSIP_DTMF_TELEPHONE_EVENT
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let requestedMode = mode == .telephoneEvent
            ? IP_PJSIP_DTMF_TELEPHONE_EVENT
            : IP_PJSIP_DTMF_IN_BAND
        guard ip_pjsip_endpoint_send_dtmf(
            handle.rawValue,
            CChar(bitPattern: ascii),
            requestedMode,
            durationMilliseconds,
            &usedMode,
            &errorBuffer,
            Int32(errorBuffer.count)
        ) else {
            let message = Self.decode(errorBuffer)
            logStore?.append(.error, category: "DTMF", message)
            throw SIPEndpointError.callFailed(message)
        }
        let actual: DTMFMode = usedMode == IP_PJSIP_DTMF_IN_BAND ? .inBand : .telephoneEvent
        let result = DTMFSendResult(requestedMode: mode, usedMode: actual)
        let fallback = result.usedFallback ? " (automatic fallback from telephone-event)" : ""
        logStore?.append(
            result.usedFallback ? .warning : .info,
            category: "DTMF",
            "Sent \(digit) using \(actual.rawValue), duration \(durationMilliseconds) ms\(fallback)"
        )
        return result
    }

    public func poll() {
        guard let handle else { return }
        ip_pjsip_endpoint_poll(handle.rawValue)
        drainSIPLogs(handle: handle.rawValue)

        let bridgeState = ip_pjsip_endpoint_registration_state(handle.rawValue)
        let code = Int(ip_pjsip_endpoint_registration_status_code(handle.rawValue))
        let expiration = ip_pjsip_endpoint_registration_expiration(handle.rawValue)
        let message = String(cString: ip_pjsip_endpoint_registration_message(handle.rawValue))
        let newState: SIPRegistrationState
        switch bridgeState.rawValue {
        case IP_PJSIP_REGISTRATION_REGISTERING.rawValue:
            newState = .registering
        case IP_PJSIP_REGISTRATION_REGISTERED.rawValue:
            newState = .registered(expiration: expiration)
        case IP_PJSIP_REGISTRATION_UNREGISTERING.rawValue:
            newState = .unregistering
        case IP_PJSIP_REGISTRATION_FAILED.rawValue:
            newState = .failed(statusCode: code, message: message)
        default:
            newState = .unregistered
        }

        if newState != registrationState {
            registrationState = newState
            switch newState {
            case let .registered(expiration):
                logStore?.append(.info, category: "REGISTER", "Registered successfully (expires in \(expiration)s)")
            case .unregistered:
                logStore?.append(.info, category: "REGISTER", "Unregistered")
            case let .failed(code, message):
                logStore?.append(.error, category: "REGISTER", "Registration failed (SIP \(code)): \(message)")
            case .registering, .unregistering:
                break
            }
        }

        updateCallState(handle: handle.rawValue)
        updateMediaState(handle: handle.rawValue)
    }

    private func drainSIPLogs(handle: OpaquePointer) {
        var buffer = [CChar](repeating: 0, count: 256)
        while ip_pjsip_endpoint_pop_sip_log(handle, &buffer, Int32(buffer.count)) {
            logStore?.append(.debug, category: "SIP Message", Self.decode(buffer))
            buffer = [CChar](repeating: 0, count: 256)
        }
    }

    private func updateMediaState(handle: OpaquePointer) {
        let bridgeState = ip_pjsip_endpoint_media_state(handle)
        let message = String(cString: ip_pjsip_endpoint_media_message(handle))
        let newState: SIPMediaState
        switch bridgeState.rawValue {
        case IP_PJSIP_MEDIA_STARTING.rawValue:
            newState = .starting
        case IP_PJSIP_MEDIA_ACTIVE.rawValue:
            newState = .active(codec: "PCMU/8000")
        case IP_PJSIP_MEDIA_FAILED.rawValue:
            newState = .failed(message: message)
        default:
            newState = .idle
        }
        if newState != mediaState {
            mediaState = newState
            switch newState {
            case let .active(codec):
                logStore?.append(.info, category: "Media", "Audio active: \(codec)")
            case let .failed(message):
                logStore?.append(.error, category: "Media", message)
            case .idle, .starting:
                break
            }
        }
        isMuted = ip_pjsip_endpoint_is_muted(handle)
        telephoneEventAvailable = ip_pjsip_endpoint_telephone_event_available(handle)
        rtpStatistics.transmittedPackets = ip_pjsip_endpoint_rtp_tx_packets(handle)
        rtpStatistics.receivedPackets = ip_pjsip_endpoint_rtp_rx_packets(handle)
        rtpStatistics.lostPackets = ip_pjsip_endpoint_rtp_rx_lost(handle)
        rtpStatistics.jitterMicroseconds = ip_pjsip_endpoint_rtp_rx_jitter_usec(handle)
    }

    private func updateCallState(handle: OpaquePointer) {
        let bridgeState = ip_pjsip_endpoint_call_state(handle)
        let code = Int(ip_pjsip_endpoint_call_status_code(handle))
        let message = String(cString: ip_pjsip_endpoint_call_message(handle))
        let remoteURI = String(cString: ip_pjsip_endpoint_remote_uri(handle))
        let newState: SIPCallState
        switch bridgeState.rawValue {
        case IP_PJSIP_CALL_OUTGOING.rawValue:
            newState = .outgoing(remoteURI: remoteURI)
        case IP_PJSIP_CALL_RINGING.rawValue:
            newState = .ringing(remoteURI: remoteURI)
        case IP_PJSIP_CALL_INCOMING.rawValue:
            newState = .incoming(remoteURI: remoteURI)
        case IP_PJSIP_CALL_CONNECTED.rawValue:
            newState = .connected(remoteURI: remoteURI)
        case IP_PJSIP_CALL_DISCONNECTING.rawValue:
            newState = .disconnecting
        case IP_PJSIP_CALL_ENDED.rawValue:
            newState = .ended(statusCode: code, message: message)
        case IP_PJSIP_CALL_FAILED.rawValue:
            newState = .failed(statusCode: code, message: message)
        default:
            newState = .idle
        }
        guard newState != callState else { return }
        callState = newState
        switch newState {
        case let .incoming(remote):
            logStore?.append(.info, category: "Call", "Incoming call from \(remote)")
        case let .ringing(remote):
            logStore?.append(.info, category: "Call", "Remote endpoint is ringing: \(remote)")
        case let .connected(remote):
            logStore?.append(.info, category: "Call", "Call connected: \(remote)")
        case let .ended(code, message):
            logStore?.append(.info, category: "Call", "Call ended (SIP \(code)): \(message)")
        case let .failed(code, message):
            logStore?.append(.error, category: "Call", "Call failed (SIP \(code)): \(message)")
        case .idle, .outgoing, .disconnecting:
            break
        }
    }

    public func stop() {
        guard let handle else {
            state = .stopped
            return
        }
        ip_pjsip_endpoint_stop(handle.rawValue)
        self.handle = nil
        state = .stopped
        registrationState = .unregistered
        callState = .idle
        mediaState = .idle
        isMuted = false
        rtpStatistics = RTPStatistics()
        telephoneEventAvailable = false
        activeTransport = nil
        logStore?.append(.info, category: "SIP", "Endpoint stopped")
    }

    private static func decode(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
        return String(decoding: bytes, as: UTF8.self)
    }
}
