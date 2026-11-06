import Foundation
import os

/// Redacted log for "View log…" and `labvpn log`, also sent to the unified log.
public final class AppLog {
    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/labvpn/labvpn.log")
    }

    private static let maximumSize = 5_000_000
    private let logger = Logger(subsystem: "de.mariusrueve.labvpn", category: "app")
    private let queue = DispatchQueue(label: "de.mariusrueve.labvpn.log")
    private let url: URL
    private let formatter = ISO8601DateFormatter()
    private var handle: FileHandle?

    public init(url: URL = AppLog.fileURL) {
        self.url = url
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > Self.maximumSize { try? manager.removeItem(at: url) }
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    public func write(_ line: String) {
        let clean = LogRedactor.redact(line)
        logger.log("\(clean, privacy: .public)")
        queue.async { [self] in
            try? handle?.write(contentsOf: Data("\(formatter.string(from: Date())) \(clean)\n".utf8))
        }
    }

    /// Waits for queued lines. For tests and shutdown.
    public func flush() { queue.sync {} }
}
