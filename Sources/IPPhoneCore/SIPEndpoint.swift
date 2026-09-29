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

    public init() {
        pjsipVersion = String(cString: ip_pjsip_version())
    }

    public func startUDP(port: UInt16 = 0) throws {
        guard handle == nil else {
            return
        }
        guard let newHandle = ip_pjsip_endpoint_create() else {
            state = .failed(message: SIPEndpointError.allocationFailed.localizedDescription)
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
            throw SIPEndpointError.startupFailed(message)
        }

        handle = PJSIPHandle(newHandle)
        state = .running(localPort: ip_pjsip_endpoint_bound_port(newHandle))
    }

    public func stop() {
        guard let handle else {
            state = .stopped
            return
        }
        ip_pjsip_endpoint_stop(handle.rawValue)
        self.handle = nil
        state = .stopped
    }
}
