import Foundation

public struct Profile: Codable, Equatable, Sendable {
    public enum Auth: String, Codable, Sendable {
        case password
        case browserSSO = "browser-sso"
    }

    public var id: String
    public var name: String
    public var host: String
    public var username: String
    public var auth: Auth
    public var forceFullTunnel: Bool
    public var mtu: Int?

    public init(id: String, name: String, host: String, username: String, auth: Auth,
                forceFullTunnel: Bool = true, mtu: Int? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.username = username
        self.auth = auth
        self.forceFullTunnel = forceFullTunnel
        self.mtu = mtu
    }

    public var gatewayHostname: String {
        String(host.prefix { $0 != "/" })
    }

    /// Why this profile can't be saved, or nil if it can.
    public var validationError: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name." }
        if username.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter your username." }
        return gatewayError ?? mtu.flatMap { (576...1500).contains($0) ? nil : "MTU must be between 576 and 1500." }
    }

    var gatewayError: String? {
        ConnectRequest.isHostname(gatewayHostname.lowercased()) ? nil : "Enter a gateway such as vpn.example.org/GROUP, without https://."
    }

    /// Arguments for the unprivileged `--authenticate` step (SPEC 5.1). Pass
    /// `resolve` to pin the gateway address (SPEC 5.2, IPv4 gateway).
    public func authenticateArguments(resolve: String? = nil) -> [String] {
        var arguments = ["--protocol=anyconnect", "--authenticate", "--user=\(username)"]
        if let resolve { arguments.append("--resolve=\(resolve)") }
        switch auth {
        case .password: arguments += ["--passwd-on-stdin", "--non-inter"]
        case .browserSSO: arguments.append("--external-browser=/usr/bin/open")
        }
        arguments.append(host)
        return arguments
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var connectOnLaunch = true
    public var autoReconnect = true
    public var fallbackToDirectAfterSeconds = 15
    public var openSSOAutomatically = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        connectOnLaunch = try values.decodeIfPresent(Bool.self, forKey: .connectOnLaunch) ?? true
        autoReconnect = try values.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
        fallbackToDirectAfterSeconds = try values.decodeIfPresent(Int.self, forKey: .fallbackToDirectAfterSeconds) ?? 15
        openSSOAutomatically = try values.decodeIfPresent(Bool.self, forKey: .openSSOAutomatically) ?? false
    }
}

public struct ProfileStore: Codable, Equatable, Sendable {
    public var defaultProfile: String
    public var profiles: [Profile]
    public var settings: AppSettings

    public init(defaultProfile: String, profiles: [Profile], settings: AppSettings = AppSettings()) {
        self.defaultProfile = defaultProfile
        self.profiles = profiles
        self.settings = settings
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        defaultProfile = try values.decode(String.self, forKey: .defaultProfile)
        profiles = try values.decode([Profile].self, forKey: .profiles)
        settings = try values.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
    }

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/labvpn/profiles.json")
    }

    public static func load(from url: URL = fileURL) throws -> ProfileStore {
        try JSONDecoder().decode(ProfileStore.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public func profile(id: String?) -> Profile? {
        profiles.first { $0.id == (id ?? defaultProfile) }
    }

    public mutating func upsert(_ profile: Profile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    public mutating func remove(id: String) {
        profiles.removeAll { $0.id == id }
        if defaultProfile == id, let first = profiles.first { defaultProfile = first.id }
    }

    /// A free id for a new profile, derived from its name.
    public func newProfileID(name: String) -> String {
        let base = name.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let stem = base.isEmpty ? "profile" : base
        var candidate = stem
        var number = 2
        while profiles.contains(where: { $0.id == candidate }) {
            candidate = "\(stem)\(number)"
            number += 1
        }
        return candidate
    }

    // MARK: Setup files (SPEC 7)

    private struct SharedProfile: Codable {
        var id, name, host: String
        var auth: Profile.Auth
        var forceFullTunnel: Bool
        var mtu: Int?
    }

    private struct SetupFile: Codable {
        var defaultProfile: String
        var profiles: [SharedProfile]
    }

    /// A `.labvpn` file: no usernames, fingerprints or secrets.
    public func exportSetup() throws -> Data {
        let shared = profiles.map {
            SharedProfile(id: $0.id, name: $0.name, host: $0.host, auth: $0.auth, forceFullTunnel: $0.forceFullTunnel, mtu: $0.mtu)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(SetupFile(defaultProfile: defaultProfile, profiles: shared))
    }

    /// Merges a `.labvpn` file. Imported profiles use `username`, or keep the one
    /// of a profile they replace. Settings and an existing default stay as they are.
    public mutating func importSetup(_ data: Data, username: String) throws {
        let file = try JSONDecoder().decode(SetupFile.self, from: data)
        let wasEmpty = profiles.isEmpty
        for shared in file.profiles {
            let existing = profiles.first { $0.id == shared.id }?.username
            let profile = Profile(id: shared.id, name: shared.name, host: shared.host, username: existing ?? username,
                                  auth: shared.auth, forceFullTunnel: shared.forceFullTunnel, mtu: shared.mtu)
            if profile.gatewayError == nil { upsert(profile) }
        }
        // A file must not quietly redirect an existing setup to its own gateway.
        guard wasEmpty else { return }
        defaultProfile = profiles.contains { $0.id == file.defaultProfile } ? file.defaultProfile : profiles.first?.id ?? ""
    }
}
