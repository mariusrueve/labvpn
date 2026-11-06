import Darwin
import Foundation
import LabVPNCore

// Talks to the app over the control socket (SPEC 9). Only `setup` and `profiles`
// work without it. Exit codes: 0 ok, 1 error, 2 app or helper unavailable,
// 3 needs user action.

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func printJSON(_ status: ControllerStatus) {
    let encoder = JSONEncoder.control
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(status) else { return }
    print(String(decoding: data, as: UTF8.self))
}

func send(_ request: ControlRequest) -> ControlResponse? {
    try? ControlClient.send(request)
}

/// Starts the app if the command calls for it, then waits for its socket.
func sendStartingApp(_ request: ControlRequest) -> ControlResponse {
    if let response = send(request) { return response }
    guard request.command.startsApp else { fail("labvpn isn't running", code: 2) }

    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "-b", "de.mariusrueve.labvpn"]
    open.standardError = FileHandle.nullDevice
    try? open.run()
    open.waitUntilExit()
    guard open.terminationStatus == 0 else { fail("Cannot start labvpn.app. Run: scripts/install.sh", code: 2) }

    for _ in 0..<40 {
        usleep(250_000)
        if let response = send(request) { return response }
    }
    fail("labvpn.app didn't respond", code: 2)
}

func waitForResult(timeout: TimeInterval) -> Never {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        guard let status = send(ControlRequest(command: .status))?.status else { fail("labvpn stopped", code: 2) }
        switch status.state {
        case .connected:
            print(status.summary)
            exit(0)
        case .needsUserAction: fail(status.message ?? "Needs user action", code: 3)
        case .failed: fail(status.message ?? "Connection failed")
        default: usleep(250_000)
        }
    }
    fail("Timed out; labvpn is still trying. See: labvpn status")
}

func value(after flag: String, in arguments: [String]) -> String? {
    arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let usage = "Usage: labvpn setup <username> | connect [<profile>] [--timeout <s>] [--no-wait] | disconnect | reconnect | status [--json] | profiles | log [--follow]"

switch arguments.first {
case "setup":
    guard arguments.count == 2 else { fail("Usage: labvpn setup <username>") }
    guard var store = try? ProfileStore.load(), !store.profiles.isEmpty else {
        fail("No profiles yet. Create one in labvpn.app first.")
    }
    store.profiles = store.profiles.map { var profile = $0; profile.username = arguments[1]; return profile }
    do { try store.save() } catch { fail("Cannot save profiles: \(error)") }
    guard let profile = store.profiles.first(where: { $0.auth == .password }) else {
        print("Saved.")
        break
    }
    guard let raw = getpass("Password for \(profile.name): ") else { fail("No password entered") }
    let password = String(cString: raw)
    guard !password.isEmpty else { fail("No password entered") }
    do { try Keychain.setPassword(password, account: Keychain.account(for: profile)) } catch { fail("Keychain error: \(error)") }
    print("Saved username and password.")

case "connect":
    var options = Array(arguments.dropFirst())
    let timeout = value(after: "--timeout", in: options).flatMap(TimeInterval.init) ?? 180
    if let index = options.firstIndex(of: "--timeout") { options.removeSubrange(index...min(index + 1, options.count - 1)) }
    let wait = !options.contains("--no-wait")
    options.removeAll { $0 == "--no-wait" }
    let response = sendStartingApp(ControlRequest(command: .connect, profile: options.first))
    if let error = response.error { fail(error) }
    if wait { waitForResult(timeout: timeout) }

case "disconnect":
    guard let response = send(ControlRequest(command: .disconnect)) else {
        print("disconnected")
        exit(0)
    }
    if let error = response.error { fail(error) }
    for _ in 0..<60 {
        guard let status = send(ControlRequest(command: .status))?.status else { break }
        if status.state == .disconnected { break }
        usleep(250_000)
    }
    print("disconnected")

case "reconnect":
    let response = sendStartingApp(ControlRequest(command: .reconnect))
    if let error = response.error { fail(error) }

case "status":
    guard let response = send(ControlRequest(command: .status)) else {
        if arguments.contains("--json") { printJSON(ControllerStatus()) } else { print("disconnected (app not running)") }
        exit(2)
    }
    if arguments.contains("--json") { printJSON(response.status) } else { print(response.status.summary) }

case "profiles":
    guard let store = try? ProfileStore.load() else { fail("No profiles. Create one in labvpn.app first.") }
    store.profiles.forEach { print("\($0.id == store.defaultProfile ? "*" : " ") \($0.id)\t\($0.host)") }

case "log":
    let path = AppLog.fileURL.path
    guard FileManager.default.fileExists(atPath: path) else { fail("No log yet") }
    var command = ["tail", "-n", "200"]
    if arguments.contains("--follow") { command.append("-f") }
    command.append(path)
    let pointers = command.map { strdup($0) } + [nil]
    execv("/usr/bin/tail", pointers)
    fail("Cannot run tail")

default:
    fail(usage)
}
