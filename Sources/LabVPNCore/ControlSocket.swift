import Darwin
import Foundation

public enum ControlCommand: String, Codable, Sendable {
    case status, connect, disconnect, reconnect

    /// `status` must never start the app, so scripts can poll it safely.
    public var startsApp: Bool { self == .connect }
}

public struct ControlRequest: Codable, Equatable, Sendable {
    public var command: ControlCommand
    public var profile: String?

    public init(command: ControlCommand, profile: String? = nil) {
        self.command = command
        self.profile = profile
    }
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public var status: ControllerStatus
    public var error: String?

    public init(status: ControllerStatus, error: String? = nil) {
        self.status = status
        self.error = error
    }
}

public enum ControlError: Error, Equatable {
    case notRunning, badResponse, pathTooLong, socket(Int32)
}

public enum ControlSocket {
    public static var path: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/labvpn/labvpn.sock").path
    }

    fileprivate static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw ControlError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// Sets timeouts, and stops a vanished peer from killing this process with SIGPIPE.
    fileprivate static func configure(_ handle: Int32, timeout seconds: Int) {
        var enabled: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(handle, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    fileprivate static func readLine(_ handle: Int32) -> Data? {
        var result = Data()
        var byte: UInt8 = 0
        while result.count < 65_536 {
            guard read(handle, &byte, 1) == 1 else { return nil }
            if byte == 0x0a { return result }
            result.append(byte)
        }
        return nil
    }

    fileprivate static func writeLine(_ handle: Int32, _ data: Data) -> Bool {
        let bytes = [UInt8](data) + [0x0a]
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { send(handle, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }
}

/// One JSON request and one JSON reply per connection.
public final class ControlServer {
    private let path: String
    private let allowedUID: uid_t
    private let handler: (ControlRequest) -> ControlResponse
    private var listener: Int32 = -1

    public init(path: String = ControlSocket.path, allowedUID: uid_t = getuid(),
                handler: @escaping (ControlRequest) -> ControlResponse) {
        self.path = path
        self.allowedUID = allowedUID
        self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        unlink(path)
        var address = try ControlSocket.address(for: path)
        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else { throw ControlError.socket(errno) }

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(handle, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(handle, 8) == 0 else {
            let failure = errno
            close(handle)
            throw ControlError.socket(failure)
        }
        listener = handle
        Thread.detachNewThread { [self] in acceptLoop(handle) }
    }

    /// The accept thread closes the socket when it leaves. Closing it here could
    /// hand the same descriptor to a new socket while that thread still uses it.
    public func stop() {
        guard listener >= 0 else { return }
        shutdown(listener, SHUT_RDWR)
        listener = -1
        unlink(path)
    }

    private func acceptLoop(_ handle: Int32) {
        defer { close(handle) }
        while true {
            let client = accept(handle, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            // A thread each: serve blocks on the socket, which would tie up GCD's pool.
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == allowedUID else { return }
        ControlSocket.configure(client, timeout: 5)
        guard let line = ControlSocket.readLine(client),
              let request = try? JSONDecoder().decode(ControlRequest.self, from: line),
              let reply = try? JSONEncoder.control.encode(handler(request)) else { return }
        _ = ControlSocket.writeLine(client, reply)
    }
}

public enum ControlClient {
    public static func send(_ request: ControlRequest, path: String = ControlSocket.path) throws -> ControlResponse {
        var address = try ControlSocket.address(for: path)
        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else { throw ControlError.socket(errno) }
        defer { close(handle) }
        ControlSocket.configure(handle, timeout: 5)

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(handle, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw ControlError.notRunning }
        guard let body = try? JSONEncoder().encode(request), ControlSocket.writeLine(handle, body),
              let line = ControlSocket.readLine(handle),
              let response = try? JSONDecoder.control.decode(ControlResponse.self, from: line)
        else { throw ControlError.badResponse }
        return response
    }
}

extension JSONEncoder {
    public static var control: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static var control: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
