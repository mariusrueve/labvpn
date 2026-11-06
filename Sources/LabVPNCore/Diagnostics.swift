import Foundation

/// Builds the "Export diagnostics" zip (SPEC 10). Everything passes through
/// `scrub`, so no username, cookie or password leaves the Mac.
public enum Diagnostics {
    public static func scrub(_ text: String, usernames: [String]) -> String {
        var result = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { LogRedactor.redact(String($0)) }
            .joined(separator: "\n")
        for username in usernames where !username.isEmpty {
            result = result.replacingOccurrences(of: username, with: "<kennung>")
        }
        return result
    }

    /// The files in the zip, by name. `run` executes a tool and returns its output.
    public static func files(store: ProfileStore?, log: String, manifest: String?, appVersion: String,
                             run: (String, [String]) -> String) -> [String: String] {
        let usernames = store?.profiles.map(\.username) ?? []
        var files = [
            "labvpn.log": scrub(log, usernames: usernames),
            "version.txt": "labvpn \(appVersion)\n\(manifest ?? "openconnect manifest missing")\n",
            "routes.txt": scrub(run("/usr/sbin/netstat", ["-rn"]), usernames: usernames),
            "dns.txt": scrub(run("/usr/sbin/scutil", ["--dns"]), usernames: usernames),
        ]
        if let store, let setup = try? store.exportSetup() {
            files["profiles.json"] = String(decoding: setup, as: UTF8.self)
        }
        return files
    }

    public static func runTool(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        guard (try? process.run()) != nil else { return "Could not run \(path)" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    public static func writeZip(_ files: [String: String], to url: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "labvpn-diagnostics-\(UUID().uuidString)")
        let root = folder.appending(path: "labvpn-diagnostics")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, text) in files { try text.write(to: root.appending(path: name), atomically: true, encoding: .utf8) }

        try? FileManager.default.removeItem(at: url)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--keepParent", root.path, url.path]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
