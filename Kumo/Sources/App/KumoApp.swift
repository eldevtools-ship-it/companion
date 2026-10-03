import SwiftUI
import AppKit

@main
struct KumoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        // Settings and files kept under the old name (Compagnon) move over before anything
        // reads them — the Settings scene below is built before the app delegate launches
        KumoMigration.run()
    }

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
