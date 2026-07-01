import SwiftUI
import WhiplashCore

@main
struct WhiplashiOSApp: App {
    @State private var roleStore = RoleStore()
    @State private var settingsStore = SettingsStore()

    var body: some Scene {
        WindowGroup {
            MainView(roleStore: roleStore, settingsStore: settingsStore)
        }
    }
}
