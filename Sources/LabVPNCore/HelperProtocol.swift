import Foundation

public enum HelperConstants {
    public static let machServiceName = "de.mariusrueve.labvpn.helper"
    public static let installRoot = "/Library/PrivilegedHelperTools/labvpn"
    public static let openconnectPath = installRoot + "/bin/openconnect"
    public static let wrapperPath = installRoot + "/scripts/labvpn-vpnc-wrapper.sh"
    public static let configPath = installRoot + "/helper.conf"
    public static let pidPath = "/var/run/labvpn/openconnect.pid"
    /// Bump when the helper, its scripts or this protocol change.
    public static let version = 4
    /// Only the signed app may drive the helper.
    public static let clientRequirement = #"anchor apple generic and identifier "de.mariusrueve.labvpn" and certificate leaf[subject.OU] = "BRW9TTP8R5""#
}

/// Root-owned, written by install-helper.sh. Never read from a user-writable path.
public struct HelperConfig: Codable, Equatable, Sendable {
    public var allowedUID: UInt32

    public init(allowedUID: UInt32) {
        self.allowedUID = allowedUID
    }
}

public struct HelperStatus: Codable, Equatable, Sendable {
    public var running: Bool
    public var pid: Int32?
    public var lastExitCode: Int32?
    public var lastLogLines: [String]
    /// Missing on helpers older than version 2.
    public var version: Int?

    public init(running: Bool, pid: Int32? = nil, lastExitCode: Int32? = nil, lastLogLines: [String] = [],
                version: Int? = HelperConstants.version) {
        self.running = running
        self.pid = pid
        self.lastExitCode = lastExitCode
        self.lastLogLines = lastLogLines
        self.version = version
    }
}

/// Closed command set (SPEC 5.3). Requests and status travel as JSON `Data`.
@objc public protocol LabVPNHelperProtocol {
    func connect(_ requestJSON: Data, reply: @escaping (String?) -> Void)
    func disconnectKeepSession(reply: @escaping (String?) -> Void)
    func disconnectLogoff(reply: @escaping (String?) -> Void)
    func status(reply: @escaping (Data) -> Void)
}
