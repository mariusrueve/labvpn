import Foundation

public enum ReauthResult: Equatable, Sendable {
    case success(AuthResult)
    case retryLater
    case needsUser(String)
}

/// Keeps a tunnel usable (SPEC 6). Recovery always starts a new openconnect
/// process: that is what worked after the in-process reconnect left a dead
/// tunnel. Stopping first restores direct routes, so reauth can reach the gateway.
public final class TunnelSupervisor {
    public enum Phase: Equatable {
        case reconnecting, fallbackDirect
    }

    public struct Actions {
        public var isRunning: () -> Bool
        public var isHealthy: () -> Bool
        public var stopKeepingSession: () -> Void
        public var stopLoggingOff: () -> Void
        public var start: (AuthResult) -> Bool
        public var reauthenticate: () -> ReauthResult
        public var wait: (TimeInterval) -> Void
        /// True once the session is being closed.
        public var isCancelled: () -> Bool
        /// Reports and clears a network change, so a doomed attempt can be dropped.
        public var takeNetworkChange: () -> Bool
        public var phaseChanged: (Phase) -> Void
        public var log: (String) -> Void

        public init(isRunning: @escaping () -> Bool, isHealthy: @escaping () -> Bool,
                    stopKeepingSession: @escaping () -> Void, start: @escaping (AuthResult) -> Bool,
                    reauthenticate: @escaping () -> ReauthResult, wait: @escaping (TimeInterval) -> Void,
                    stopLoggingOff: @escaping () -> Void = {},
                    isCancelled: @escaping () -> Bool = { false }, takeNetworkChange: @escaping () -> Bool = { false },
                    phaseChanged: @escaping (Phase) -> Void = { _ in }, log: @escaping (String) -> Void) {
            self.isRunning = isRunning
            self.isHealthy = isHealthy
            self.stopKeepingSession = stopKeepingSession
            self.stopLoggingOff = stopLoggingOff
            self.start = start
            self.reauthenticate = reauthenticate
            self.wait = wait
            self.isCancelled = isCancelled
            self.takeNetworkChange = takeNetworkChange
            self.phaseChanged = phaseChanged
            self.log = log
        }
    }

    public enum Outcome: Equatable {
        case healthy, degraded, recovered, cancelled, lost
        case needsUser(String)
    }

    private enum Attempt {
        /// `exited` is what a rejected cookie looks like. `unusable` means the
        /// tunnel is alive but silent or never started: the network is the likely
        /// cause, so logging in again would only stack up sessions on the gateway.
        case succeeded, exited, unusable, interrupted, cancelled
    }

    public static let backoff: [TimeInterval] = [5, 10, 30, 60]
    public var failureThreshold = 3
    public var startPolls = 20
    public var pollInterval: TimeInterval = 1
    public var autoRecover = true

    private var auth: AuthResult
    private let actions: Actions
    private var failures = 0

    public init(auth: AuthResult, actions: Actions) {
        self.auth = auth
        self.actions = actions
    }

    /// Call on a regular interval.
    public func tick() -> Outcome {
        guard actions.isRunning() else {
            guard autoRecover else { return .lost }
            actions.log("openconnect exited; reconnecting…")
            return recover()
        }
        if actions.isHealthy() {
            failures = 0
            return .healthy
        }
        failures += 1
        guard failures >= failureThreshold else { return .degraded }
        guard autoRecover else { return .lost }
        actions.log("Tunnel is passing no traffic; reconnecting…")
        return recover()
    }

    /// The physical network changed, so the old connection can't work. Skips
    /// the health-check wait and openconnect's own retry sleeps.
    public func networkChanged() -> Outcome {
        guard autoRecover else { return tick() }
        actions.log("Network changed; reconnecting…")
        return recover()
    }

    /// After wake, one failed check is enough, then recovery starts.
    public func didWake() -> Outcome {
        failures = max(failures, failureThreshold - 1)
        return tick()
    }

    private func recover() -> Outcome {
        var attempt = 0
        actions.phaseChanged(.reconnecting)
        _ = actions.takeNetworkChange()
        while true {
            actions.stopKeepingSession()
            switch startAndWait() {
            case .succeeded: return finished()
            case .cancelled: return .cancelled
            case .interrupted: continue
            case .unusable: actions.stopKeepingSession()
            case .exited:
                switch actions.reauthenticate() {
                case .success(let fresh):
                    auth = fresh
                    switch startAndWait() {
                    case .succeeded: return finished()
                    case .cancelled: return .cancelled
                    case .interrupted: continue
                    case .exited, .unusable: actions.stopLoggingOff()
                    }
                case .retryLater:
                    break
                case .needsUser(let message):
                    return .needsUser(message)
                }
            }
            if actions.isCancelled() { return .cancelled }

            let delay = Self.backoff[min(attempt, Self.backoff.count - 1)]
            attempt += 1
            actions.phaseChanged(.fallbackDirect)
            actions.log("Still offline; traffic goes direct. Retrying in \(Int(delay)) s…")
            actions.wait(delay)
            if actions.isCancelled() { return .cancelled }
            _ = actions.takeNetworkChange()
        }
    }

    private func finished() -> Outcome {
        failures = 0
        actions.log("Tunnel restored.")
        return .recovered
    }

    private func startAndWait() -> Attempt {
        if actions.isCancelled() { return .cancelled }
        guard actions.start(auth) else { return .unusable }
        for _ in 0..<startPolls {
            actions.wait(pollInterval)
            if actions.isCancelled() { return .cancelled }
            if actions.takeNetworkChange() { return .interrupted }
            guard actions.isRunning() else { return .exited }
            if actions.isHealthy() { return .succeeded }
        }
        return .unusable
    }
}
