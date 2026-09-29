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

public enum SIPEndpointError: LocalizedError, Equatable {
    case allocationFailed
    case startupFailed(String)
    case registrationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .allocationFailed:
            "PJSIP endpoint allocation failed."
        case let .startupFailed(message):
            message
        case let .registrationFailed(message):
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

    public let pjsipVersion: String

    private var handle: PJSIPHandle?
    private weak var logStore: AppLogStore?

    public init(logStore: AppLogStore? = nil) {
        self.logStore = logStore
        pjsipVersion = String(cString: ip_pjsip_version())
        logStore?.append(.info, category: "SIP", "PJSIP \(pjsipVersion) loaded")
    }

    public func startUDP(port: UInt16 = 0) throws {
        guard handle == nil else {
            return
        }
        guard let newHandle = ip_pjsip_endpoint_create() else {
            state = .failed(message: SIPEndpointError.allocationFailed.localizedDescription)
            logStore?.append(.error, category: "SIP", SIPEndpointError.allocationFailed.localizedDescription)
            throw SIPEndpointError.allocationFailed
        }

        var errorBuffer = [CChar](repeating: 0, count: 512)
        let started = ip_pjsip_endpoint_start_udp(
            newHandle,
            port,
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
        logStore?.append(.info, category: "SIP", "UDP endpoint started on local port \(boundPort)")
    }

    public func register(settings: SIPSettings, password: String) throws {
        guard let handle else {
            throw SIPEndpointError.registrationFailed("SIP endpoint is not running.")
        }
        guard settings.transport == .udp else {
            throw SIPEndpointError.registrationFailed("Only UDP REGISTER is available in this milestone.")
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

    public func poll() {
        guard let handle else { return }
        ip_pjsip_endpoint_poll(handle.rawValue)

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

        guard newState != registrationState else { return }
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

    public func stop() {
        guard let handle else {
            state = .stopped
            return
        }
        ip_pjsip_endpoint_stop(handle.rawValue)
        self.handle = nil
        state = .stopped
        registrationState = .unregistered
        logStore?.append(.info, category: "SIP", "Endpoint stopped")
    }

    private static func decode(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
        return String(decoding: bytes, as: UTF8.self)
    }
}
