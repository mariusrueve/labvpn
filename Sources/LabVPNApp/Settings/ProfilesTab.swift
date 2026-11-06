import LabVPNCore
import SwiftUI
import UniformTypeIdentifiers

struct ProfilesTab: View {
    @ObservedObject var model: AppModel
    @State private var selection: String?
    @State private var draft: Profile?
    @State private var password = ""
    @State private var message: String?
    @State private var isTesting = false

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading) {
                List(model.profiles, id: \.id, selection: $selection) { profile in
                    HStack {
                        Text(profile.name)
                        if profile.id == model.store?.defaultProfile {
                            Spacer()
                            Text("Default").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("Add") { add() }
                    Button("Import…") { importFile() }
                    Button("Export…") { exportFile() }
                }
            }
            .frame(width: 210)

            if draft != nil { editor } else {
                Text("Select a profile").foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = model.store?.defaultProfile } ; load(selection) }
        .onChange(of: selection) { _, id in
            // Add and Save change the selection themselves; keep their draft and message.
            if let id, id != draft?.id { load(id) }
        }
    }

    @ViewBuilder private var editor: some View {
        VStack(alignment: .leading) {
            Form {
                TextField("Name", text: field(\.name))
                TextField("Gateway", text: field(\.host))
                TextField("Username", text: field(\.username))
                Picker("Sign-in", selection: field(\.auth)) {
                    Text("Password").tag(Profile.Auth.password)
                    Text("Browser (SSO)").tag(Profile.Auth.browserSSO)
                }
                if draft?.auth == .password {
                    SecureField("Password", text: $password, prompt: Text("Unchanged"))
                }
                Toggle("Force full tunnel", isOn: field(\.forceFullTunnel))
                Picker("MTU", selection: field(\.mtu)) {
                    Text("Automatic").tag(Int?.none)
                    Text("1347 (Cisco workaround)").tag(Int?.some(1347))
                }
            }
            .formStyle(.grouped)

            if let message { Text(message).foregroundStyle(.secondary) }
            HStack {
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                Button(isTesting ? "Testing…" : "Test Connection") { test() }.disabled(isTesting)
                Spacer()
                Button("Set as Default") { if let id = draft?.id { model.setDefault(profileID: id) } }
                    .disabled(draft?.id == model.store?.defaultProfile || !isSaved)
                Button("Delete", role: .destructive) { remove() }
                    .disabled(!isSaved || model.profiles.count < 2)
            }
        }
    }

    private static let blank = Profile(id: "", name: "", host: "", username: "", auth: .password)

    private var isSaved: Bool { model.profiles.contains { $0.id == draft?.id } }

    private func field<Value>(_ keyPath: WritableKeyPath<Profile, Value>) -> Binding<Value> {
        Binding(get: { (draft ?? Self.blank)[keyPath: keyPath] }, set: { draft?[keyPath: keyPath] = $0 })
    }

    private func load(_ id: String?) {
        draft = model.profiles.first { $0.id == id }
        password = ""
        message = nil
    }

    private func add() {
        selection = nil
        draft = Profile(id: "", name: "New Profile", host: "", username: model.profiles.first?.username ?? "", auth: .password)
        password = ""
        message = nil
    }

    private func save() {
        guard var profile = draft else { return }
        if profile.id.isEmpty { profile.id = model.newProfileID(name: profile.name) }
        if let error = model.save(profile: profile, password: password) {
            message = error
            return
        }
        draft = profile
        selection = profile.id
        password = ""
        message = "Saved."
    }

    private func test() {
        guard let profile = draft else { return }
        guard isSaved else {
            message = "Save the profile first."
            return
        }
        isTesting = true
        message = profile.auth == .browserSSO ? "Finish signing in in your browser…" : nil
        Task {
            message = await model.testConnection(profile: profile, password: password)
            isTesting = false
        }
    }

    private func remove() {
        guard let id = draft?.id else { return }
        model.delete(profileID: id)
        selection = model.store?.defaultProfile
        load(selection)
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "vpn-setup.labvpn"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        message = model.exportSetup(to: url) ?? "Exported. It contains no username or password."
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "labvpn") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        message = model.importSetup(from: url) ?? "Imported."
    }
}
