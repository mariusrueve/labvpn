import Foundation

/// Runs the scripts inside the app as root, through the macOS admin prompt.
enum HelperInstaller {
    enum Action {
        case install, uninstall

        fileprivate var script: String {
            switch self {
            case .install: "install-helper.sh"
            case .uninstall: "uninstall-helper.sh"
            }
        }
    }

    /// Returns an error message, or nil on success or if the user cancels.
    static func run(_ action: Action) async -> String? {
        await Task.detached { perform(action) }.value
    }

    private static func perform(_ action: Action) -> String? {
        let bundle = Bundle.main.bundleURL
        let script = bundle.appending(path: "Contents/Library/Helper/scripts/\(action.script)").path
        guard FileManager.default.isExecutableFile(atPath: script) else { return "This build has no helper." }

        // The user is about to hand this script root, so check it hasn't changed.
        let check = execute("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.path])
        guard check.status == 0 else { return "labvpn.app is damaged. Reinstall it." }

        let source = """
        on run argv
            do shell script (quoted form of item 1 of argv) & " " & (item 2 of argv) ¬
                with prompt "labvpn needs to change its VPN helper." with administrator privileges
        end run
        """
        let result = execute("/usr/bin/osascript", ["-e", source, script, action == .install ? String(getuid()) : ""])
        if result.status == 0 || result.output.contains("-128") { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func execute(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (1, "Could not run \(path)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
