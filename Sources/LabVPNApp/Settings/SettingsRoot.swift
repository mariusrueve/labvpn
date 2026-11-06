import LabVPNCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsRoot: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.needsSetup {
            FirstRunView(model: model)
        } else {
            TabView {
                ProfilesTab(model: model).tabItem { Text("Profiles") }
                GeneralTab(model: model).tabItem { Text("General") }
                HelperTab(model: model).tabItem { Text("Helper") }
                AboutTab(model: model).tabItem { Text("About") }
            }
            .padding()
        }
    }
}

private struct FirstRunView: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var gateway = ""
    @State private var auth = Profile.Auth.password
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up labvpn").font(.title2)
            if let file = model.pendingSetupFile {
                Text("Using \(file.lastPathComponent). Enter your login below.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Enter your VPN gateway, or use a setup file from a colleague.")
                    .foregroundStyle(.secondary)
            }
            Form {
                if model.pendingSetupFile == nil {
                    TextField("Name", text: $name, prompt: Text("My VPN"))
                    TextField("Gateway", text: $gateway, prompt: Text("vpn.example.org/GROUP"))
                    Picker("Sign-in", selection: $auth) {
                        Text("Password").tag(Profile.Auth.password)
                        Text("Browser (SSO)").tag(Profile.Auth.browserSSO)
                    }
                }
                TextField("Username", text: $username)
                if auth == .password || model.pendingSetupFile != nil {
                    SecureField("Password", text: $password)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            Text("Your password is stored in your Keychain. macOS then asks for an admin password to install the VPN helper.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                if model.pendingSetupFile == nil {
                    Button("Use Setup File…") { chooseFile() }
                } else {
                    Button("Enter Gateway Instead") { model.pendingSetupFile = nil }
                }
                Spacer()
                Button("Save and Connect") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "labvpn") ?? .json]
        if panel.runModal() == .OK { model.pendingSetupFile = panel.url }
    }

    private func save() {
        if let file = model.pendingSetupFile {
            error = model.finishSetup(file: file, username: username, password: password)
            return
        }
        let title = name.trimmingCharacters(in: .whitespaces)
        let profile = Profile(id: model.newProfileID(name: title), name: title, host: gateway,
                              username: username.trimmingCharacters(in: .whitespaces), auth: auth)
        error = model.finishSetup(profile: profile, password: password)
    }
}

private struct GeneralTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Toggle("Connect on launch", isOn: binding(\.connectOnLaunch))
            Toggle("Reconnect automatically", isOn: binding(\.autoReconnect))
            Stepper(value: binding(\.fallbackToDirectAfterSeconds), in: 5...120, step: 5) {
                Text("openconnect gives up after \(model.settings.fallbackToDirectAfterSeconds) s")
            }
            Toggle("Open SSO sign-in automatically when a session expires", isOn: binding(\.openSSOAutomatically))
        }
        .formStyle(.grouped)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { value in model.updateSettings { $0[keyPath: keyPath] = value } })
    }
}

private struct HelperTab: View {
    @ObservedObject var model: AppModel
    @State private var isWorking = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(statusText, systemImage: model.helperIsCurrent ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.helperIsCurrent ? Color.green : Color.orange)
            Text("The helper runs as root and starts the tunnel. Installing it asks for an admin password, and disconnects the VPN.")
                .foregroundStyle(.secondary)
            HStack {
                Button(model.helperVersion == nil ? "Install Helper…" : model.helperIsCurrent ? "Reinstall…" : "Update Helper…") {
                    perform { await model.installHelper() }
                }
                if model.helperVersion != nil {
                    Button("Uninstall…", role: .destructive) { perform { await model.uninstallHelper() } }
                }
                Button("Check Again") { model.checkHelper() }
            }
            .disabled(isWorking)
            if let result { Text(result).foregroundStyle(.secondary) }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func perform(_ action: @escaping () async -> String?) {
        isWorking = true
        result = nil
        Task {
            result = await action()
            isWorking = false
        }
    }

    private var statusText: String {
        if model.helperIsCurrent { return "Helper installed (version \(HelperConstants.version))" }
        if let version = model.helperVersion { return "Helper is outdated (version \(version))" }
        return "Helper isn't installed"
    }
}

private struct AboutTab: View {
    @ObservedObject var model: AppModel
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("labvpn \(model.appVersion)").font(.title3)
            Text(model.openconnectManifest?.split(separator: "\n").first.map(String.init) ?? "openconnect isn't installed")
                .foregroundStyle(.secondary)
            HStack {
                Button("View Log") { model.viewLog() }
                Button("Export Diagnostics…") { exportDiagnostics() }
                Button("Licenses") { model.showLicenses() }
            }
            if let result { Text(result).foregroundStyle(.secondary) }
            Text("Diagnostics contain routes and DNS servers, but no username, cookie or password.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "labvpn-diagnostics.zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let error = await model.exportDiagnostics(to: url)
            result = error ?? "Saved \(url.lastPathComponent)."
        }
    }
}
