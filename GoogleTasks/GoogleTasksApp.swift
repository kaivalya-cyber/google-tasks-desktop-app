import SwiftUI

@main
struct GoogleTasksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(DataManager.shared)
        }
    }
}
