import CPJSIPBridge
import Foundation

public enum SIPEndpointState: Equatable, Sendable {
    case stopped
    case running(localPort: UInt16)
    case failed(message: String)
}

public enum SIPEndpointError: LocalizedError, Equatable {
    case allocationFailed
    case startupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .allocationFailed:
            "PJSIP endpoint allocation failed."
        case let .startupFailed(message):
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

    public func stop() {
        guard let handle else {
            state = .stopped
            return
        }
        ip_pjsip_endpoint_stop(handle.rawValue)
        self.handle = nil
        state = .stopped
        logStore?.append(.info, category: "SIP", "Endpoint stopped")
    }
}
