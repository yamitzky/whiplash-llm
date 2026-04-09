import SwiftUI

struct SettingsView: View {
    let roleStore: RoleStore
    let settingsStore: SettingsStore

    var body: some View {
        TabView {
            GeneralTab(settingsStore: settingsStore)
                .tabItem {
                    Label("一般", systemImage: "gear")
                }

            BackendTab(settingsStore: settingsStore)
                .tabItem {
                    Label("AIバックエンド", systemImage: "cpu")
                }

            RoleTab(roleStore: roleStore, settingsStore: settingsStore)
                .tabItem {
                    Label("Role", systemImage: "person.text.rectangle")
                }
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}
