import Darwin
import Foundation
import LabVPNCore
import os

@_silgen_name("proc_pidpath")
private func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32

let logger = Logger(subsystem: "de.mariusrueve.labvpn", category: "helper")
let openconnectLogger = Logger(subsystem: "de.mariusrueve.labvpn", category: "openconnect")

/// Owns the single openconnect process. All state is touched on `queue`.
final class TunnelManager {
    private let queue = DispatchQueue(label: "de.mariusrueve.labvpn.tunnel")
    private var process: Process?
    private var lastExitCode: Int32?
    private var logLines: [String] = []
    private(set) var ownerID: ObjectIdentifier?

    func start(_ request: ConnectRequest, owner: ObjectIdentifier) throws {
        try queue.sync {
            if process?.isRunning == true { stopAndWait() }

            let child = Process()
            child.executableURL = URL(fileURLWithPath: HelperConstants.openconnectPath)
            child.arguments = request.openconnectArguments(wrapperPath: HelperConstants.wrapperPath)
            child.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LABVPN_FORCE_FULL_TUNNEL": request.forceFullTunnel ? "1" : "0",
            ]
            let input = Pipe(), output = Pipe()
            child.standardInput = input
            child.standardOutput = output
            child.standardError = output
            let cookie = request.cookie
            capture(output.fileHandleForReading, secrets: [cookie])
            child.terminationHandler = { [weak self] finished in
                self?.queue.async {
                    guard let self, self.process === finished else { return }
                    try? FileManager.default.removeItem(atPath: HelperConstants.pidPath)
                    // Killed outright, so vpnc-script's disconnect never ran.
                    if finished.terminationReason == .uncaughtSignal {
                        logger.error("openconnect was killed; restoring the network")
                        clearStaleState()
                    }
                    self.lastExitCode = finished.terminationStatus
                    self.process = nil
                    self.ownerID = nil
                    logger.log("openconnect exited with \(finished.terminationStatus)")
                }
            }
            try child.run()
            // The throwing form: openconnect may already have exited.
            try? input.fileHandleForWriting.write(contentsOf: Data((cookie + "\n").utf8))
            try? input.fileHandleForWriting.close()
            try? FileManager.default.createDirectory(atPath: (HelperConstants.pidPath as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            try? String(child.processIdentifier).write(toFile: HelperConstants.pidPath, atomically: true, encoding: .utf8)
            process = child
            ownerID = owner
            lastExitCode = nil
            logLines.removeAll()
        }
    }

    func signal(_ number: Int32) -> String? {
        queue.sync {
            guard let process, process.isRunning else { return "No tunnel is running" }
            kill(process.processIdentifier, number)
            return nil
        }
    }

    func status() -> HelperStatus {
        queue.sync {
            HelperStatus(running: process?.isRunning == true, pid: process?.processIdentifier,
                         lastExitCode: lastExitCode, lastLogLines: logLines)
        }
    }

    func clientWentAway(_ client: ObjectIdentifier) {
        queue.async {
            guard self.ownerID == client, let process = self.process, process.isRunning else { return }
            logger.log("Tunnel owner disconnected; logging off")
            kill(process.processIdentifier, SIGTERM)
        }
    }

    /// Runs on `queue`. Logging off runs vpnc-script, so allow it time to finish.
    private func stopAndWait() {
        guard let process else { return }
        kill(process.processIdentifier, SIGTERM)
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { usleep(100_000) }
        self.process = nil
    }

    private func capture(_ handle: FileHandle, secrets: [String]) {
        var buffer = Data()
        handle.readabilityHandler = { [weak self] file in
            let chunk = file.availableData
            if chunk.isEmpty { file.readabilityHandler = nil; return }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                let clean = LogRedactor.redact(line, secrets: secrets)
                openconnectLogger.log("\(clean, privacy: .public)")
                self?.queue.async {
                    self?.logLines.append(clean)
                    if let count = self?.logLines.count, count > 200 { self?.logLines.removeFirst(count - 200) }
                }
            }
        }
    }
}

final class HelperService: NSObject, LabVPNHelperProtocol {
    private let tunnel: TunnelManager
    private let config: HelperConfig
    private let clientID: ObjectIdentifier

    init(tunnel: TunnelManager, config: HelperConfig, clientID: ObjectIdentifier) {
        self.tunnel = tunnel
        self.config = config
        self.clientID = clientID
    }

    func connect(_ requestJSON: Data, reply: @escaping (String?) -> Void) {
        do {
            let request = try JSONDecoder().decode(ConnectRequest.self, from: requestJSON)
            try request.validate()
            try tunnel.start(request, owner: clientID)
            reply(nil)
        } catch {
            logger.error("Connect refused: \(String(describing: error), privacy: .public)")
            reply("Connect refused: \(error)")
        }
    }

    func disconnectKeepSession(reply: @escaping (String?) -> Void) { reply(tunnel.signal(SIGHUP)) }
    func disconnectLogoff(reply: @escaping (String?) -> Void) { reply(tunnel.signal(SIGTERM)) }

    func status(reply: @escaping (Data) -> Void) {
        reply((try? JSONEncoder().encode(tunnel.status())) ?? Data())
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let tunnel = TunnelManager()
    private let config: HelperConfig

    init(config: HelperConfig) { self.config = config }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard UInt32(connection.effectiveUserIdentifier) == config.allowedUID else {
            logger.error("Rejected XPC client with uid \(connection.effectiveUserIdentifier)")
            return false
        }
        connection.setCodeSigningRequirement(HelperConstants.clientRequirement)
        let clientID = ObjectIdentifier(connection)
        connection.exportedInterface = NSXPCInterface(with: LabVPNHelperProtocol.self)
        connection.exportedObject = HelperService(tunnel: tunnel, config: config, clientID: clientID)
        let tunnel = self.tunnel
        connection.invalidationHandler = { tunnel.clientWentAway(clientID) }
        connection.interruptionHandler = { tunnel.clientWentAway(clientID) }
        connection.resume()
        return true
    }
}

/// Stops an openconnect left behind by a previous helper, so two tunnels can't
/// run at once. Checks the path, because the pid may have been reused.
func stopOrphan() {
    guard let text = try? String(contentsOfFile: HelperConstants.pidPath, encoding: .utf8),
          let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
    defer { try? FileManager.default.removeItem(atPath: HelperConstants.pidPath) }
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
          String(cString: buffer) == HelperConstants.openconnectPath else { return }
    logger.log("Stopping orphaned openconnect \(pid)")
    kill(pid, SIGTERM)
    for _ in 0..<50 {
        usleep(100_000)
        if kill(pid, 0) != 0 { return }
    }
    kill(pid, SIGKILL)
}

func clearStaleState() {
    let cleanup = Process()
    cleanup.executableURL = URL(fileURLWithPath: "/bin/sh")
    cleanup.arguments = [HelperConstants.wrapperPath]
    cleanup.environment = ["reason": "labvpn-cleanup"]
    try? cleanup.run()
    cleanup.waitUntilExit()
}

guard let data = FileManager.default.contents(atPath: HelperConstants.configPath),
      let config = try? JSONDecoder().decode(HelperConfig.self, from: data) else {
    logger.fault("Cannot read \(HelperConstants.configPath, privacy: .public)")
    exit(1)
}

signal(SIGPIPE, SIG_IGN)
stopOrphan()
clearStaleState()
let delegate = ListenerDelegate(config: config)
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
logger.log("labvpn-helper started")
dispatchMain()
