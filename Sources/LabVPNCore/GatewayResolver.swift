import Darwin
import Foundation

/// Finds the gateway's IPv4 address. vpnc-script's route to an IPv6 gateway
/// fails on macOS, and the IPv6 reject routes would then block reconnects.
public enum GatewayResolver {
    public static func resolveArgument(hostname: String) -> String? {
        ipv4Address(hostname: hostname).map { "\(hostname):\($0)" }
    }

    public static func ipv4Address(hostname: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buffer)
    }
}
