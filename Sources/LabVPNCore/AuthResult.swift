import Darwin
import Foundation

/// The result of `openconnect --authenticate`, which prints shell assignments.
public struct AuthResult: Equatable, Sendable {
    public let cookie: String
    public let host: String
    public let connectURL: String
    public let fingerprint: String
    public let resolve: String?

    /// Parses stdout from `--authenticate`. Values may be single-quoted, with
    /// embedded quotes written as `'\''`. Returns nil if a required key is absent.
    public static func parse(_ output: String) -> AuthResult? {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            guard ["COOKIE", "HOST", "CONNECT_URL", "FINGERPRINT", "RESOLVE"].contains(key) else { continue }
            values[key] = unquote(String(line[line.index(after: equals)...]))
        }
        guard let cookie = values["COOKIE"], !cookie.isEmpty,
              let host = values["HOST"], !host.isEmpty,
              let connectURL = values["CONNECT_URL"], !connectURL.isEmpty,
              let fingerprint = values["FINGERPRINT"], !fingerprint.isEmpty
        else { return nil }
        let resolve = values["RESOLVE"].flatMap { $0.isEmpty ? nil : $0 }
        return AuthResult(cookie: cookie, host: host, connectURL: connectURL, fingerprint: fingerprint, resolve: resolve)
    }

    /// A redirect can land on a node reached over IPv6, past the pin given to
    /// `--authenticate`. The tunnel must use IPv4 (SPEC 5.2), so re-resolve the
    /// host in `CONNECT_URL`. It's the same node, so the cookie stays valid.
    public func preferringIPv4(lookup: (String) -> String? = GatewayResolver.ipv4Address) -> AuthResult {
        if let resolve, let colon = resolve.firstIndex(of: ":") {
            var address = in_addr()
            if inet_pton(AF_INET, String(resolve[resolve.index(after: colon)...]), &address) == 1 { return self }
        }
        guard let hostname = URLComponents(string: connectURL)?.host, let ipv4 = lookup(hostname) else { return self }
        return AuthResult(cookie: cookie, host: host, connectURL: connectURL, fingerprint: fingerprint,
                          resolve: "\(hostname):\(ipv4)")
    }

    private static func unquote(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") else { return raw }
        return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
    }
}
