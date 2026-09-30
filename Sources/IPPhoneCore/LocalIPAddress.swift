import Darwin
import Foundation

public struct LocalIPAddress: Equatable, Identifiable, Sendable {
    public let interfaceName: String
    public let address: String

    public var id: String { "\(interfaceName):\(address)" }

    /// Lists addresses on active interfaces, including loopback for local tests.
    /// Scoped IPv6 addresses are omitted because SIP URIs cannot carry zone IDs.
    public static func available() throws -> [LocalIPAddress] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { freeifaddrs(interfaces) }

        var addresses: [LocalIPAddress] = []
        var current = interfaces
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            guard interface.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let socketAddress = interface.pointee.ifa_addr
            else { continue }
            let family = Int32(socketAddress.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                socketAddress, socklen_t(socketAddress.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let address = String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            guard isValid(address) else { continue }
            let item = LocalIPAddress(
                interfaceName: String(cString: interface.pointee.ifa_name),
                address: address
            )
            if !addresses.contains(item) { addresses.append(item) }
        }
        return addresses.sorted {
            if $0.interfaceName != $1.interfaceName { return $0.interfaceName < $1.interfaceName }
            return $0.address < $1.address
        }
    }

    /// Returns the source address the OS would use to reach a SIP server.
    /// Connecting a UDP socket selects a route without sending a packet.
    public static func routedSourceAddress(to host: String, port: UInt16) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        var resolved: UnsafeMutablePointer<addrinfo>?
        let result = host.withCString { name in
            String(port).withCString { service in
                getaddrinfo(name, service, &hints, &resolved)
            }
        }
        guard result == 0 else { return nil }
        defer { freeaddrinfo(resolved) }

        var current = resolved
        while let candidate = current {
            defer { current = candidate.pointee.ai_next }
            let descriptor = socket(candidate.pointee.ai_family, SOCK_DGRAM, IPPROTO_UDP)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            guard connect(descriptor, candidate.pointee.ai_addr, candidate.pointee.ai_addrlen) == 0 else {
                continue
            }
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let named = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }
            guard named == 0 else { continue }
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let readable = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, length, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
                }
            }
            guard readable == 0 else { continue }
            let addressText = String(decoding: hostBuffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            if isValid(addressText) { return addressText }
        }
        return nil
    }

    public static func isValid(_ address: String) -> Bool {
        guard !address.utf8.contains(0) else { return false }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            return value != 0 && value < 0xE0000000
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, address, &ipv6) == 1 else { return false }
        return withUnsafeBytes(of: ipv6) { bytes in
            !bytes.allSatisfy { $0 == 0 }
                && bytes[0] != 0xFF
                && !(bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80)
        }
    }
}
