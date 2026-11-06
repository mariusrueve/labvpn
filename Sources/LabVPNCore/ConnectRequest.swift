import Foundation

/// Everything the helper needs to start a tunnel. Crosses XPC as JSON. The
/// cookie is written to openconnect's stdin and never appears on argv.
public struct ConnectRequest: Codable, Equatable, Sendable {
    public var connectURL: String
    public var cookie: String
    public var fingerprint: String
    public var resolve: String?
    public var mtu: Int?
    public var reconnectTimeout: Int
    public var forceFullTunnel: Bool

    public init(connectURL: String, cookie: String, fingerprint: String, resolve: String?,
                mtu: Int? = nil, reconnectTimeout: Int = 15, forceFullTunnel: Bool = true) {
        self.connectURL = connectURL
        self.cookie = cookie
        self.fingerprint = fingerprint
        self.resolve = resolve
        self.mtu = mtu
        self.reconnectTimeout = reconnectTimeout
        self.forceFullTunnel = forceFullTunnel
    }
}

public enum ValidationError: Error, Equatable {
    case invalidURL, invalidCookie, invalidFingerprint, invalidResolve, invalidMTU, invalidTimeout
}

extension ConnectRequest {
    /// Every value here reaches a root process. Nothing that passes may start
    /// with `-`, so no value can act as a flag.
    public func validate() throws {
        guard let components = URLComponents(string: connectURL),
              components.scheme == "https",
              let host = components.host?.lowercased(), Self.isHostname(host),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              connectURL.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7f })
        else { throw ValidationError.invalidURL }
        guard !cookie.isEmpty, cookie.utf8.count <= 8192,
              !cookie.contains(where: \.isNewline) else { throw ValidationError.invalidCookie }
        guard Self.isFingerprint(fingerprint) else { throw ValidationError.invalidFingerprint }
        if let resolve, !Self.isResolve(resolve) { throw ValidationError.invalidResolve }
        if let mtu, !(576...1500).contains(mtu) { throw ValidationError.invalidMTU }
        guard (1...3600).contains(reconnectTimeout) else { throw ValidationError.invalidTimeout }
    }

    /// Arguments for the root openconnect process.
    public func openconnectArguments(wrapperPath: String) -> [String] {
        var arguments = [
            "--protocol=anyconnect", "--cookie-on-stdin",
            "--servercert=\(fingerprint)",
            "--script=\(wrapperPath)",
            "--reconnect-timeout=\(reconnectTimeout)",
        ]
        if let resolve { arguments.append("--resolve=\(resolve)") }
        if let mtu { arguments.append("--mtu=\(mtu)") }
        arguments.append(connectURL)
        return arguments
    }

    static func isHostname(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 253 && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" }
        }
    }

    private static func isFingerprint(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefABCDEF0123456789")
        if value.hasPrefix("pin-sha256:") {
            let body = value.dropFirst("pin-sha256:".count)
            let base64 = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/="))
            return body.count == 44 && body.unicodeScalars.allSatisfy { $0.isASCII && base64.contains($0) }
        }
        if value.hasPrefix("sha256:") || value.hasPrefix("sha1:") {
            let body = value.split(separator: ":", maxSplits: 1)[1]
            return body.count >= 40 && body.count <= 64 && body.unicodeScalars.allSatisfy(allowed.contains)
        }
        return value.count == 40 && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isResolve(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":") else { return false }
        let host = String(value[..<colon]).lowercased()
        var address = String(value[value.index(after: colon)...])
        if address.hasPrefix("["), address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
        guard isHostname(host), !address.isEmpty else { return false }
        var ipv4 = in_addr(), ipv6 = in6_addr()
        return inet_pton(AF_INET, address, &ipv4) == 1 || inet_pton(AF_INET6, address, &ipv6) == 1
    }
}
