import AppKit
import Combine
import LabVPNCore
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status = ControllerStatus()
    @Published private(set) var store: ProfileStore?
    @Published private(set) var launchAtLogin = LoginItem.isEnabled
    @Published private(set) var now = Date()

    @Published private(set) var helperVersion: Int?
    /// A `.labvpn` file opened before any profile exists.
    @Published var pendingSetupFile: URL?

    private let log = AppLog()
    private let helper = HelperClient()
    private let controller: TunnelController
    private let watcher = NetworkWatcher()
    private var server: ControlServer?
    private var observers: [Any] = []
    private var clock: AnyCancellable?
    private var fallbackAlert: Task<Void, Never>?

    var profiles: [Profile] { store?.profiles ?? [] }
    var settings: AppSettings { store?.settings ?? AppSettings() }
    var needsSetup: Bool { profiles.isEmpty }

    /// Asks for the Settings window. Set by the app delegate.
    var showSettings: () -> Void = {}

    init() {
        let log = self.log
        let authenticator = Authenticator { log.write($0) }
        controller = TunnelController(
            helper: helper,
            authenticator: authenticator,
            probe: { TunnelEnvironment.current().map { TunnelProbe.isHealthy($0) } ?? false },
            tunnelAddress: { TunnelEnvironment.current()?.address },
            log: { log.write($0) }
        )
    }

    func start() {
        log.write("labvpn started")
        reloadProfiles()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let controller = self.controller
        let log = self.log
        controller.onChange = { [weak self] status in
            Task { @MainActor in self?.apply(status) }
        }
        watcher.onChange = {
            log.write("Physical network changed")
            controller.networkChanged()
        }
        watcher.start()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            log.write("Woke from sleep")
            controller.didWake()
        })
        clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { [weak self] in self?.now = $0 }

        let control = ControlServer { [weak self] request in
            DispatchQueue.main.sync { MainActor.assumeIsolated { self?.handle(request) } }
                ?? ControlResponse(status: ControllerStatus(), error: "Shutting down")
        }
        do {
            try control.start()
            server = control
        } catch {
            log.write("Cannot open the control socket: \(error)")
        }

        if needsSetup {
            checkHelper()
            showSettings()
        } else if settings.connectOnLaunch {
            Task { await connectAfterCheckingHelper() }
        } else {
            checkHelper()
        }
    }

    /// Runs off the main thread: the XPC call blocks.
    func checkHelper() {
        Task { await refreshHelper() }
    }

    private func refreshHelper() async {
        let helper = self.helper
        helperVersion = await Task.detached { helper.status()?.version }.value
    }

    var helperIsCurrent: Bool { helperVersion == HelperConstants.version }

    /// Installs or updates the helper through the admin prompt. Returns an error
    /// message, or nil once the current helper answers.
    func installHelper() async -> String? {
        if isActive { controller.disconnect() }
        if let error = await HelperInstaller.run(.install) { return error }
        for _ in 0..<20 {
            await refreshHelper()
            if helperIsCurrent { return nil }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return "The helper isn't responding. If you cancelled the password prompt, try again."
    }

    func uninstallHelper() async -> String? {
        if isActive { controller.disconnect() }
        let error = await HelperInstaller.run(.uninstall)
        await refreshHelper()
        return error
    }

    /// A missing or old helper is replaced first, which asks for the admin password.
    private func connectAfterCheckingHelper() async {
        await refreshHelper()
        if !helperIsCurrent, let error = await installHelper() {
            log.write(error)
            notify("labvpn", error)
            return
        }
        connect(profileID: nil)
    }

    func shutdown() {
        watcher.stop()
        server?.stop()
        controller.shutdown()
        log.flush()
    }

    // MARK: Actions

    var isActive: Bool { ![.disconnected, .failed, .needsUserAction].contains(status.state) }

    func connect(profileID: String?) {
        guard let error = startConnection(profileID: profileID) else { return }
        log.write(error)
        notify("labvpn", error)
    }

    func disconnect() { controller.disconnect() }

    /// A sign-in the user can start: an SSO profile waiting on them.
    var canSignIn: Bool {
        status.state == .needsUserAction && profiles.first { $0.id == status.profileID }?.auth == .browserSSO
    }

    func signIn() { connect(profileID: status.profileID) }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        guard var store else { return }
        change(&store.settings)
        save(store)
    }

    // MARK: Profiles

    /// Returns an error message, or nil once saved. An empty password keeps the stored one.
    func save(profile: Profile, password: String) -> String? {
        if let error = profile.validationError { return error }
        var updated = store ?? ProfileStore(defaultProfile: profile.id, profiles: [])
        let previous = updated.profiles.first { $0.id == profile.id }
        if let previous, previous.username != profile.username, profile.auth == .password, password.isEmpty {
            return "Enter the password for the new username."
        }
        updated.upsert(profile)
        if !password.isEmpty {
            do {
                try Keychain.setPassword(password, account: Keychain.account(for: profile))
            } catch {
                return "Keychain error: \(error.localizedDescription)"
            }
        }
        save(updated)
        return nil
    }

    func delete(profileID: String) {
        guard var updated = store, let profile = updated.profile(id: profileID) else { return }
        if status.profileID == profileID { disconnect() }
        Keychain.deletePassword(account: Keychain.account(for: profile))
        updated.remove(id: profileID)
        save(updated)
    }

    func setDefault(profileID: String) {
        guard var updated = store else { return }
        updated.defaultProfile = profileID
        save(updated)
    }

    func newProfileID(name: String) -> String {
        (store ?? ProfileStore(defaultProfile: "", profiles: [])).newProfileID(name: name)
    }

    /// First run with a profile entered by hand.
    func finishSetup(profile: Profile, password: String) -> String? {
        if let error = profile.validationError { return error }
        if profile.auth == .password, password.isEmpty { return "Enter your password." }
        return complete(ProfileStore(defaultProfile: profile.id, profiles: [profile]), password: password)
    }

    /// First run from a `.labvpn` file. The password goes to its password profiles.
    func finishSetup(file: URL, username: String, password: String) -> String? {
        let name = username.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Enter your username." }
        var imported = ProfileStore(defaultProfile: "", profiles: [])
        do {
            try imported.importSetup(Data(contentsOf: file), username: name)
        } catch {
            return "That isn't a labvpn setup file."
        }
        if imported.profiles.isEmpty { return "That file has no usable profiles." }
        return complete(imported, password: password)
    }

    private func complete(_ new: ProfileStore, password: String) -> String? {
        var updated = new
        updated.settings = settings
        if !password.isEmpty {
            do {
                for profile in updated.profiles where profile.auth == .password {
                    try Keychain.setPassword(password, account: Keychain.account(for: profile))
                }
            } catch {
                return "Keychain error: \(error.localizedDescription)"
            }
        }
        save(updated)
        pendingSetupFile = nil
        Task { await connectAfterCheckingHelper() }
        return nil
    }

    /// Logs in without starting a tunnel, off the main thread. Returns a result to show.
    func testConnection(profile: Profile, password: String) async -> String {
        if let error = profile.validationError { return error }
        if !password.isEmpty, profile.auth == .password {
            try? Keychain.setPassword(password, account: Keychain.account(for: profile))
        }
        let log = self.log
        return await Task.detached {
            switch Authenticator(log: { log.write($0) }).authenticate(profile, interactive: true) {
            case .success: "Login works."
            case .retryLater: "Cannot reach the gateway."
            case .needsUser(let message): message
            }
        }.value
    }

    private func save(_ updated: ProfileStore) {
        do {
            try updated.save()
        } catch {
            log.write("Cannot save profiles: \(error)")
            notify("labvpn", "Cannot save profiles: \(error.localizedDescription)")
        }
        reloadProfiles()
    }

    // MARK: Files

    func exportSetup(to url: URL) -> String? {
        do {
            guard let store else { return "Nothing to export." }
            try store.exportSetup().write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Returns an error message, or nil once imported.
    func importSetup(from url: URL) -> String? {
        do {
            var updated = store ?? ProfileStore(defaultProfile: "zbh", profiles: [])
            let before = updated
            try updated.importSetup(Data(contentsOf: url), username: profiles.first?.username ?? "")
            guard updated != before else { return "That file has no usable profiles." }
            save(updated)
            return nil
        } catch {
            return "That isn't a labvpn setup file."
        }
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    var openconnectManifest: String? {
        try? String(contentsOfFile: HelperConstants.installRoot + "/MANIFEST.txt", encoding: .utf8)
    }

    func exportDiagnostics(to url: URL) async -> String? {
        log.flush()
        let store = self.store, manifest = openconnectManifest, version = appVersion
        return await Task.detached {
            let text = (try? String(contentsOf: AppLog.fileURL, encoding: .utf8)) ?? ""
            let files = Diagnostics.files(store: store, log: text, manifest: manifest, appVersion: version,
                                          run: Diagnostics.runTool)
            do {
                try Diagnostics.writeZip(files, to: url)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
        } catch {
            log.write("Launch at login failed: \(error)")
            notify("labvpn", "Launch at login failed: \(error.localizedDescription)")
        }
        launchAtLogin = LoginItem.isEnabled
    }

    func viewLog() { NSWorkspace.shared.open(AppLog.fileURL) }

    func showLicenses() {
        NSWorkspace.shared.open(Bundle.main.bundleURL.appending(path: "Contents/Resources/ThirdParty"))
    }

    // MARK: Internals

    private func reloadProfiles() {
        guard let loaded = try? ProfileStore.load() else { return }
        store = loaded
        controller.autoReconnect = loaded.settings.autoReconnect
    }

    /// Returns an error message, or nil once the connection has been started.
    private func startConnection(profileID: String?) -> String? {
        reloadProfiles()
        guard let store = try? ProfileStore.load() else { return "No profiles yet. Add one in Settings." }
        guard let profile = store.profile(id: profileID) else { return "Unknown profile \(profileID ?? "")" }
        let current = controller.status
        if current.profileID == profile.id,
           [.authenticating, .connecting, .connected, .reconnecting, .fallbackDirect].contains(current.state) {
            return nil
        }
        controller.connect(profile, reconnectTimeout: store.settings.fallbackToDirectAfterSeconds)
        return nil
    }

    private func handle(_ request: ControlRequest) -> ControlResponse {
        var error: String?
        switch request.command {
        case .status:
            break
        case .connect:
            error = startConnection(profileID: request.profile)
        case .disconnect:
            controller.disconnect()
        case .reconnect:
            if [.connected, .reconnecting, .fallbackDirect].contains(controller.status.state) {
                controller.networkChanged()
            } else {
                error = "Not connected"
            }
        }
        return ControlResponse(status: controller.status, error: error)
    }

    private func apply(_ new: ControllerStatus) {
        let old = status
        status = new
        guard old.state != new.state else { return }
        log.write("State: \(new.summary)")

        fallbackAlert?.cancel()
        fallbackAlert = nil
        switch new.state {
        case .needsUserAction where new.sessionExpired:
            if settings.openSSOAutomatically {
                signIn()
            } else {
                notify("\(new.profileName ?? "VPN") session expired", "Click to sign in.", action: Self.signInAction)
            }
        case .needsUserAction, .failed:
            notify("labvpn", new.message ?? new.state.rawValue)
        case .fallbackDirect:
            fallbackAlert = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                self?.notify("labvpn", "The VPN has been down for over a minute; traffic is going direct.")
            }
        default:
            break
        }
    }

    static let signInAction = "signIn"

    private func notify(_ title: String, _ body: String, action: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let action { content.userInfo = ["action": action] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
