import Foundation
import ServiceManagement

/// Launch at login. `SMAppService` may refuse an ad-hoc signed app, so fall back
/// to a per-user LaunchAgent.
enum LoginItem {
    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/de.mariusrueve.labvpn.plist")
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled || FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            do {
                try SMAppService.mainApp.register()
            } catch {
                try writeAgent()
            }
        } else {
            try? SMAppService.mainApp.unregister()
            try? FileManager.default.removeItem(at: agentURL)
        }
    }

    private static func writeAgent() throws {
        let plist: [String: Any] = [
            "Label": "de.mariusrueve.labvpn",
            "ProgramArguments": ["/usr/bin/open", "-g", "-b", "de.mariusrueve.labvpn"],
            "RunAtLoad": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: agentURL, options: .atomic)
    }
}
