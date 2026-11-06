import Darwin
import Foundation

/// What the wrapper recorded about the running tunnel.
public struct TunnelEnvironment: Equatable, Sendable {
    public static let path = "/var/run/labvpn/connect-env.txt"

    public var interface: String
    public var dnsServers: [String]
    public var address: String? = nil

    public static func parse(_ text: String) -> TunnelEnvironment? {
        var interface: String?
        var servers: [String] = []
        var address: String?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("TUNDEV=") { interface = String(line.dropFirst("TUNDEV=".count)) }
            if line.hasPrefix("INTERNAL_IP4_ADDRESS=") { address = String(line.dropFirst("INTERNAL_IP4_ADDRESS=".count)) }
            if line.hasPrefix("INTERNAL_IP4_DNS=") {
                servers = line.dropFirst("INTERNAL_IP4_DNS=".count).split(separator: " ").map(String.init)
            }
        }
        guard let interface, !interface.isEmpty, !servers.isEmpty else { return nil }
        return TunnelEnvironment(interface: interface, dnsServers: servers, address: address)
    }

    public static func current() -> TunnelEnvironment? {
        (try? String(contentsOfFile: path, encoding: .utf8)).flatMap(parse)
    }
}

/// Proves traffic flows by asking the gateway-pushed DNS server a question.
/// The process being alive proves nothing: after wake, openconnect can report a
/// reconnect and still pass no traffic, and ZBH has dead-peer detection off.
public enum TunnelProbe {
    public static func isHealthy(_ environment: TunnelEnvironment, timeout: TimeInterval = 2) -> Bool {
        environment.dnsServers.contains {
            dnsResponds(server: $0, interface: environment.interface, timeout: timeout)
        }
    }

    public static func query(id: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in ["uni-hamburg", "de"] {
            bytes.append(UInt8(label.utf8.count))
            bytes.append(contentsOf: label.utf8)
        }
        return bytes + [0, 0, 1, 0, 1]
    }

    /// `interface` binds the socket to the tunnel, so an answer can't arrive
    /// over the direct path.
    public static func dnsResponds(server: String, port: UInt16 = 53, interface: String?, timeout: TimeInterval) -> Bool {
        let handle = socket(AF_INET, SOCK_DGRAM, 0)
        guard handle >= 0 else { return false }
        defer { close(handle) }

        if let interface {
            var index = if_nametoindex(interface)
            guard index != 0,
                  setsockopt(handle, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout.size(ofValue: index))) == 0
            else { return false }
        }
        var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, server, &address.sin_addr) == 1 else { return false }

        let id = UInt16.random(in: 1...UInt16.max)
        let packet = query(id: id)
        let sent = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(handle, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == packet.count else { return false }

        var reply = [UInt8](repeating: 0, count: 512)
        let received = recv(handle, &reply, reply.count, 0)
        return received >= 12 && reply[0] == UInt8(id >> 8) && reply[1] == UInt8(id & 0xff) && reply[2] & 0x80 != 0
    }
}
