import AppKit
import LabVPNCore
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        model.showSettings = { [weak self] in self?.openSettings() }
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }

    /// Double-clicking a `.labvpn` file.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if model.needsSetup {
                model.pendingSetupFile = url
            } else if let error = model.importSetup(from: url) {
                show(error)
            }
        }
        openSettings()
    }

    func openSettings() {
        model.checkHelper()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsRoot(model: model)))
            window.title = "labvpn Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 640, height: 460))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func show(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.notification.request.content.userInfo["action"] as? String
        Task { @MainActor in
            if action == AppModel.signInAction { self.model.signIn() }
            completionHandler()
        }
    }
}

@main
struct LabVPNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model) { delegate.openSettings() }
        } label: {
            MenuLabel(model: delegate.model)
        }
    }
}

private struct MenuLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        switch model.status.state {
        case .connected: "lock.shield.fill"
        case .disconnected: "shield.slash"
        case .authenticating, .connecting, .reconnecting, .disconnecting: "arrow.triangle.2.circlepath"
        case .fallbackDirect: "wifi.exclamationmark"
        case .needsUserAction, .failed: "exclamationmark.triangle.fill"
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void

    var body: some View {
        Text(model.status.menuTitle(now: model.now))
        if let message = model.status.message { Text(message) }
        Divider()

        if model.canSignIn {
            Button("Sign in…") { model.signIn() }
        }
        if model.isActive {
            Button(model.status.state == .authenticating ? "Cancel" : "Disconnect") { model.disconnect() }
        } else {
            Button("Connect") { model.connect(profileID: nil) }
                .disabled(model.needsSetup)
        }
        Menu("Connect to") {
            ForEach(model.profiles, id: \.id) { profile in
                Button(profile.name) { model.connect(profileID: profile.id) }
            }
        }
        .disabled(model.needsSetup)
        Divider()

        Button("Settings…", action: openSettings)
            .keyboardShortcut(",")
        Button("View Log…") { model.viewLog() }
        Divider()
        Button("Quit labvpn") { NSApplication.shared.terminate(nil) }
    }
}
