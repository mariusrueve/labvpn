import Foundation

public protocol Authenticating: AnyObject {
    /// `interactive` is false during recovery: SSO must not open a browser unasked (SPEC 6.3).
    func authenticate(_ profile: Profile, interactive: Bool) -> ReauthResult
    func cancel()
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        defer { lock.unlock() }
        value = true
    }
}

/// Runs `openconnect --authenticate` unprivileged (SPEC 5.1).
public final class Authenticator: Authenticating {
    private let lock = NSLock()
    private var running: Process?
    private let log: (String) -> Void
    private let executable: String
    private let signInTimeout: TimeInterval

    public init(executable: String = HelperConstants.openconnectPath, signInTimeout: TimeInterval = 300,
                log: @escaping (String) -> Void) {
        self.executable = executable
        self.signInTimeout = signInTimeout
        self.log = log
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        running?.terminate()
    }

    public func authenticate(_ profile: Profile, interactive: Bool) -> ReauthResult {
        if profile.auth == .browserSSO, !interactive {
            return .needsUser("\(profile.name) session expired. Sign in again.")
        }
        let resolve = GatewayResolver.resolveArgument(hostname: profile.gatewayHostname)
        if resolve == nil {
            if !interactive { return .retryLater }
            log("Warning: no IPv4 address for the gateway; reconnects may fail")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = profile.authenticateArguments(resolve: resolve)
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        var password: String?
        if profile.auth == .password {
            password = Keychain.password(account: Keychain.account(for: profile))
            if password == nil { return .needsUser("No password stored for \(profile.name). Add it in Settings → Profiles.") }
        }

        do { try process.run() } catch {
            return .needsUser("Cannot start openconnect. Install the helper in Settings → Helper.")
        }
        lock.lock()
        running = process
        lock.unlock()
        defer {
            lock.lock()
            running = nil
            lock.unlock()
        }

        if let password { input.fileHandleForWriting.write(Data((password + "\n").utf8)) }
        try? input.fileHandleForWriting.close()

        // Nothing reports a closed browser window, so sign-in needs a time limit.
        let timedOut = TimeoutFlag()
        let limit = DispatchWorkItem {
            timedOut.set()
            process.terminate()
        }
        if profile.auth == .browserSSO {
            DispatchQueue.global().asyncAfter(deadline: .now() + signInTimeout, execute: limit)
        }
        defer { limit.cancel() }

        var errorText = ""
        let reader = DispatchGroup()
        DispatchQueue.global().async(group: reader) {
            errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        reader.wait()
        process.waitUntilExit()

        if timedOut.isSet { return .needsUser("Sign-in timed out. Sign in again when you're ready.") }

        let secrets = password.map { [$0] } ?? []
        errorText.split(whereSeparator: \.isNewline).forEach { log(LogRedactor.redact(String($0), secrets: secrets)) }

        let result = Self.classify(status: process.terminationStatus, output: text, errors: errorText)
        if case .success(let auth) = result { return .success(auth.preferringIPv4()) }
        return result
    }

    static func classify(status: Int32, output: String, errors: String) -> ReauthResult {
        if status == 0, let result = AuthResult.parse(output) { return .success(result) }
        // Stop on the first rejected password, so retries can't lock the account.
        if ["Login failed", "User input required"].contains(where: errors.contains) {
            return .needsUser("The gateway rejected the login. Check it in Settings → Profiles.")
        }
        return .retryLater
    }
}
