import Darwin
import Foundation
import Network

/// Decides when the real network changed. The identity includes the IPv4
/// address, because an iPhone hotspot stays on `en0`, so the name alone misses
/// that switch. Tunnel interfaces are ignored: reacting to our own tunnel coming
/// up would cause a reconnect loop (SPEC 6.2).
public struct PhysicalPathTracker: Sendable {
    private var seen = false
    private var current: String?

    public init() {}

    public static func isPhysical(_ name: String) -> Bool {
        !["utun", "ipsec", "ppp", "lo", "gif", "stf", "awdl", "llw", "bridge", "anpi", "ap"].contains { name.hasPrefix($0) }
    }

    public static func identity(interfaces: [String], address: (String) -> String?) -> String? {
        for name in interfaces where isPhysical(name) {
            if let ip = address(name) { return "\(name)/\(ip)" }
        }
        return nil
    }

    /// True when `identity` is a usable network that differs from the last one.
    /// The first value only sets the baseline.
    public mutating func update(_ identity: String?) -> Bool {
        defer {
            current = identity
            seen = true
        }
        guard seen else { return false }
        return identity != nil && identity != current
    }
}

/// Reports physical network changes, debounced (SPEC 6.2).
public final class NetworkWatcher {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "de.mariusrueve.labvpn.network")
    private let debounce: TimeInterval
    private var tracker = PhysicalPathTracker()
    private var pending: DispatchWorkItem?

    public var onChange: (() -> Void)?

    public init(debounce: TimeInterval = 2) { self.debounce = debounce }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path)
        }
        monitor.start(queue: queue)
    }

    public func stop() { monitor.cancel() }

    private func handle(_ path: NWPath) {
        let names = path.availableInterfaces.map(\.name)
        let identity = path.status == .satisfied
            ? PhysicalPathTracker.identity(interfaces: names, address: Self.ipv4Address)
            : nil
        let changed = tracker.update(identity)
        guard changed || identity == nil else { return }
        pending?.cancel()
        pending = nil
        guard changed else { return }
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    static func ipv4Address(of interface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var entry = head
        while let current = entry {
            defer { entry = current.pointee.ifa_next }
            guard String(cString: current.pointee.ifa_name) == interface,
                  let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            return String(cString: buffer)
        }
        return nil
    }
}
