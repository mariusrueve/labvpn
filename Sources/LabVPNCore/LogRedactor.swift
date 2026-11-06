import Foundation

/// Removes secrets from openconnect output before it reaches any log.
public enum LogRedactor {
    private static let patterns: [NSRegularExpression] = [
        #"(?i)(webvpn=)[^;\s]+"#,
        #"(?i)(cookie[:=]\s*)\S+"#,
        #"(?i)(password[:=]\s*)\S+"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    public static func redact(_ line: String, secrets: [String] = []) -> String {
        var result = line
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "<redacted>")
        }
        for pattern in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: "$1<redacted>")
        }
        return result
    }
}
