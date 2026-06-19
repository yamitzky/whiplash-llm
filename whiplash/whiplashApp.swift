import SwiftUI

@main
struct WhiplashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 標準の Settings シーンに本物の設定画面を載せることで、
        // ⌘, をネイティブに一本化する（自前の NSWindow は持たない）。
        // 表示時に .regular へ、クローズ検知は AppDelegate 側の willClose 監視で行う
        // （Settings シーンの .onDisappear はクローズ時に発火する保証がないため）。
        Settings {
            SettingsView(
                roleStore: appDelegate.roleStore,
                settingsStore: appDelegate.settingsStore
            )
            .onAppear { appDelegate.settingsWindowDidAppear() }
        }
    }
}
