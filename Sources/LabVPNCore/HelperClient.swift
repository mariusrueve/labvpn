import Foundation

/// What the controller needs from the root helper. Errors are returned as text.
public protocol TunnelHelper: AnyObject {
    func connect(_ request: ConnectRequest) -> String?
    func disconnectKeepSession() -> String?
    func disconnectLogoff() -> String?
    func status() -> HelperStatus?
}

/// One long-lived XPC connection. The helper logs the tunnel off when its owner
/// goes away, so the process holding this object owns the tunnel.
public final class HelperClient: TunnelHelper {
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    public init() {}

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let fresh = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        fresh.remoteObjectInterface = NSXPCInterface(with: LabVPNHelperProtocol.self)
        fresh.invalidationHandler = { [weak self] in self?.forget(fresh) }
        fresh.interruptionHandler = { [weak self] in self?.forget(fresh) }
        fresh.resume()
        connection = fresh
        return fresh
    }

    private func forget(_ stale: NSXPCConnection) {
        lock.lock()
        defer { lock.unlock() }
        if connection === stale { connection = nil }
    }

    /// Runs one call and blocks until the helper replies or the link fails.
    private func call(_ body: (LabVPNHelperProtocol) -> Void) -> Bool {
        var linkFailed = false
        let proxy = currentConnection().synchronousRemoteObjectProxyWithErrorHandler { _ in linkFailed = true }
        guard let helper = proxy as? LabVPNHelperProtocol else { return false }
        body(helper)
        return !linkFailed
    }

    private static let unavailable = "The labvpn helper isn't available. Install it in Settings → Helper."

    public func connect(_ request: ConnectRequest) -> String? {
        guard let json = try? JSONEncoder().encode(request) else { return "Cannot encode the request" }
        var error: String?
        return call { $0.connect(json) { error = $0 } } ? error : Self.unavailable
    }

    public func disconnectKeepSession() -> String? {
        var error: String?
        return call { $0.disconnectKeepSession { error = $0 } } ? error : Self.unavailable
    }

    public func disconnectLogoff() -> String? {
        var error: String?
        return call { $0.disconnectLogoff { error = $0 } } ? error : Self.unavailable
    }

    public func status() -> HelperStatus? {
        var data: Data?
        guard call({ $0.status { data = $0 } }), let data else { return nil }
        return try? JSONDecoder().decode(HelperStatus.self, from: data)
    }
}
