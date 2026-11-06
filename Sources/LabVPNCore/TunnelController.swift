import Foundation

/// The connection states in SPEC 6.
public enum ConnectionState: String, Codable, Sendable {
    case disconnected, authenticating, connecting, connected, reconnecting
    case fallbackDirect, needsUserAction, failed, disconnecting
}

public struct ControllerStatus: Codable, Equatable, Sendable {
    public var state: ConnectionState
    public var profileID: String?
    public var profileName: String?
    public var tunnelAddress: String?
    public var connectedSince: Date?
    public var message: String?
    /// An SSO session ran out during recovery, as opposed to a failed sign-in.
    public var sessionExpired: Bool

    public init(state: ConnectionState = .disconnected, profileID: String? = nil, profileName: String? = nil,
                tunnelAddress: String? = nil, connectedSince: Date? = nil, message: String? = nil,
                sessionExpired: Bool = false) {
        self.state = state
        self.profileID = profileID
        self.profileName = profileName
        self.tunnelAddress = tunnelAddress
        self.connectedSince = connectedSince
        self.message = message
        self.sessionExpired = sessionExpired
    }

    /// The status line in the menu (SPEC 8.1).
    public func menuTitle(now: Date = Date()) -> String {
        let name = profileName.map { " · \($0)" } ?? ""
        switch state {
        case .disconnected: return "Disconnected"
        case .authenticating: return "Signing in\(name)…"
        case .connecting: return "Connecting\(name)…"
        case .reconnecting: return "Reconnecting\(name)…"
        case .fallbackDirect: return "Reconnecting (direct)\(name)"
        case .disconnecting: return "Disconnecting…"
        case .needsUserAction: return "Needs attention\(name)"
        case .failed: return "Failed\(name)"
        case .connected:
            var title = "Connected\(name)"
            if let connectedSince {
                let minutes = max(0, Int(now.timeIntervalSince(connectedSince) / 60))
                title += minutes < 60 ? " · \(minutes)m" : " · \(minutes / 60)h \(minutes % 60)m"
            }
            if let tunnelAddress { title += " · \(tunnelAddress)" }
            return title
        }
    }

    /// The first word is `connected` only while connected, for scripts.
    public var summary: String {
        var parts = [state == .fallbackDirect ? "reconnecting (direct)" : state.rawValue]
        if let profileName { parts.append(profileName) }
        if state == .connected, let tunnelAddress { parts.append(tunnelAddress) }
        if let message { parts.append(message) }
        return parts.joined(separator: " · ")
    }
}

/// Owns one VPN session at a time on a worker thread. Calls return immediately,
/// and changes arrive through `onChange`, on an arbitrary thread.
public final class TunnelController {
    public struct Timing {
        public var tick: TimeInterval = 5
        public var poll: TimeInterval = 1
        public var firstConnectPolls = 20
        public var stopPolls = 100
        public var stopPoll: TimeInterval = 0.1
        public var backoffScale: TimeInterval = 1
        public init() {}
    }

    private let helper: TunnelHelper
    private let authenticator: Authenticating
    private let probe: () -> Bool
    private let tunnelAddress: () -> String?
    private let log: (String) -> Void
    private let timing: Timing
    private let worker = DispatchQueue(label: "de.mariusrueve.labvpn.controller")

    private let lock = NSCondition()
    private var current = ControllerStatus()
    private var session = 0
    private var pendingNetworkChange = false
    private var pendingWake = false
    private var interrupted = false

    public var autoReconnect = true
    public var onChange: ((ControllerStatus) -> Void)?

    public init(helper: TunnelHelper, authenticator: Authenticating, probe: @escaping () -> Bool,
                tunnelAddress: @escaping () -> String?, log: @escaping (String) -> Void, timing: Timing = Timing()) {
        self.helper = helper
        self.authenticator = authenticator
        self.probe = probe
        self.tunnelAddress = tunnelAddress
        self.log = log
        self.timing = timing
    }

    public var status: ControllerStatus {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Ends any running session (logging it off), then starts this profile.
    public func connect(_ profile: Profile, reconnectTimeout: Int = 15) {
        let id = beginSession()
        authenticator.cancel()
        update { $0 = ControllerStatus(state: .authenticating, profileID: profile.id, profileName: profile.name) }
        worker.async { [self] in run(profile, reconnectTimeout: reconnectTimeout, id: id) }
    }

    public func disconnect() {
        _ = beginSession()
        authenticator.cancel()
    }

    /// Blocks until the tunnel has been logged off.
    public func shutdown() {
        disconnect()
        worker.sync {}
    }

    public func networkChanged() {
        lock.lock()
        pendingNetworkChange = true
        interrupted = true
        lock.broadcast()
        lock.unlock()
    }

    public func didWake() {
        lock.lock()
        pendingWake = true
        interrupted = true
        lock.broadcast()
        lock.unlock()
    }

    // MARK: Session

    private func beginSession() -> Int {
        lock.lock()
        defer { lock.unlock() }
        session += 1
        interrupted = true
        pendingNetworkChange = false
        pendingWake = false
        lock.broadcast()
        return session
    }

    private func isCancelled(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return session != id
    }

    private func take(_ flag: ReferenceWritableKeyPath<TunnelController, Bool>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = self[keyPath: flag]
        self[keyPath: flag] = false
        return value
    }

    /// Starting a session sets the interrupt too. Left set, it would cut the first
    /// wait short. Cancelling doesn't depend on it: `isCancelled` is checked directly.
    private func clearInterrupt() {
        lock.lock()
        defer { lock.unlock() }
        if !pendingNetworkChange, !pendingWake { interrupted = false }
    }

    /// Sleeps, but ends early on a network change, wake or cancel.
    private func pause(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(seconds)
        while !interrupted, lock.wait(until: deadline) {}
        interrupted = false
    }

    private func update(_ change: (inout ControllerStatus) -> Void) {
        lock.lock()
        let before = current
        change(&current)
        let after = current
        lock.unlock()
        if before != after { onChange?(after) }
    }

    private func set(_ state: ConnectionState, message: String? = nil) {
        update {
            $0.state = state
            $0.message = message
            if state != .connected, state != .reconnecting, state != .fallbackDirect {
                $0.connectedSince = nil
                $0.tunnelAddress = nil
            }
        }
    }

    private func markConnected() {
        let address = tunnelAddress()
        update {
            $0.state = .connected
            $0.message = nil
            $0.tunnelAddress = address
            if $0.connectedSince == nil { $0.connectedSince = Date() }
        }
    }

    private func run(_ profile: Profile, reconnectTimeout: Int, id: Int) {
        guard !isCancelled(id) else {
            logOff()
            return
        }
        update { $0 = ControllerStatus(state: .authenticating, profileID: profile.id, profileName: profile.name) }
        clearInterrupt()

        guard let auth = firstLogin(profile, id: id) else { return }

        func start(_ auth: AuthResult) -> Bool {
            let request = ConnectRequest(connectURL: auth.connectURL, cookie: auth.cookie, fingerprint: auth.fingerprint,
                                         resolve: auth.resolve, mtu: profile.mtu, reconnectTimeout: reconnectTimeout,
                                         forceFullTunnel: profile.forceFullTunnel)
            if let error = helper.connect(request) {
                log(error)
                return false
            }
            logCursor = 0
            return true
        }

        set(.connecting)
        guard start(auth) else {
            finish(id, .failed, message: "The helper didn't start the tunnel. Check Settings → Helper.")
            return
        }

        // If the probe never works here it can't be trusted, and it must not
        // restart a good tunnel.
        var probeWorks = false
        for _ in 0..<timing.firstConnectPolls where !probeWorks {
            pause(timing.poll)
            if isCancelled(id) { break }
            guard refreshRunning() else { break }
            probeWorks = probe()
        }
        if isCancelled(id) {
            logOff()
            return
        }
        if !probeWorks {
            if refreshRunning() {
                log("Warning: health check isn't working; a silent tunnel won't be detected.")
            } else {
                finish(id, .failed, message: "openconnect exited. See View log…")
                return
            }
        }
        markConnected()

        let supervisor = TunnelSupervisor(auth: auth, actions: .init(
            isRunning: { [unowned self] in refreshRunning() },
            isHealthy: { [unowned self] in !probeWorks || probe() },
            stopKeepingSession: { [unowned self] in stopKeepingSession() },
            start: start,
            reauthenticate: { [unowned self] in authenticator.authenticate(profile, interactive: false) },
            wait: { [unowned self] in pause($0) },
            stopLoggingOff: { [unowned self] in
                if refreshRunning() {
                    _ = helper.disconnectLogoff()
                    waitUntilStopped()
                }
            },
            isCancelled: { [unowned self] in isCancelled(id) },
            takeNetworkChange: { [unowned self] in take(\.pendingNetworkChange) },
            phaseChanged: { [unowned self] in set($0 == .reconnecting ? .reconnecting : .fallbackDirect) },
            log: log
        ))
        supervisor.pollInterval = timing.poll
        supervisor.autoRecover = autoReconnect

        while !isCancelled(id) {
            let outcome: TunnelSupervisor.Outcome
            if take(\.pendingNetworkChange) {
                outcome = supervisor.networkChanged()
            } else if take(\.pendingWake) {
                outcome = supervisor.didWake()
            } else {
                outcome = supervisor.tick()
            }

            switch outcome {
            case .healthy, .recovered:
                markConnected()
            case .degraded:
                break
            case .cancelled:
                continue
            case .lost:
                stopKeepingSession()
                finish(id, .failed, message: "The tunnel stopped working")
                return
            case .needsUser(let message):
                stopKeepingSession()
                finish(id, .needsUserAction, message: message, sessionExpired: profile.auth == .browserSSO)
                return
            }
            if !hasPendingEvent { pause(timing.tick) }
        }
        logOff()
    }

    /// Logs in, waiting for the network if needed: at login Wi-Fi may join after
    /// the app starts. SSO profiles don't wait, so a browser can't open repeatedly.
    /// Returns nil once the session has been finished.
    private func firstLogin(_ profile: Profile, id: Int) -> AuthResult? {
        var attempt = 0
        while true {
            switch authenticator.authenticate(profile, interactive: true) {
            case .success(let result):
                if isCancelled(id) {
                    logOff()
                    return nil
                }
                return result
            case .needsUser(let message):
                finish(id, .needsUserAction, message: message)
                return nil
            case .retryLater:
                if isCancelled(id) {
                    logOff()
                    return nil
                }
                guard profile.auth == .password else {
                    finish(id, .failed, message: "Cannot reach the gateway")
                    return nil
                }
            }
            set(.connecting, message: "Waiting for network…")
            pause(TunnelSupervisor.backoff[min(attempt, TunnelSupervisor.backoff.count - 1)] * timing.backoffScale)
            attempt += 1
            _ = take(\.pendingNetworkChange)
            if isCancelled(id) {
                logOff()
                return nil
            }
            set(.authenticating)
        }
    }

    private var hasPendingEvent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingNetworkChange || pendingWake
    }

    /// Ends a session that won't be recovered, unless a newer one has taken over.
    private func finish(_ id: Int, _ state: ConnectionState, message: String, sessionExpired: Bool = false) {
        guard !isCancelled(id) else {
            logOff()
            return
        }
        log(message)
        set(state, message: message)
        update { $0.sessionExpired = sessionExpired }
    }

    private func logOff() {
        if refreshRunning() {
            set(.disconnecting)
            _ = helper.disconnectLogoff()
            waitUntilStopped()
        }
        update { $0 = ControllerStatus() }
    }

    private func stopKeepingSession() {
        guard refreshRunning() else { return }
        _ = helper.disconnectKeepSession()
        waitUntilStopped()
    }

    private func waitUntilStopped() {
        for _ in 0..<timing.stopPolls where refreshRunning() {
            Thread.sleep(forTimeInterval: timing.stopPoll)
        }
    }

    // MARK: Helper log

    private var logCursor = 0

    @discardableResult
    private func refreshRunning() -> Bool {
        guard let status = helper.status() else { return false }
        let lines = status.lastLogLines
        if lines.count < logCursor { logCursor = 0 }
        lines[logCursor...].forEach(log)
        logCursor = lines.count
        return status.running
    }
}
