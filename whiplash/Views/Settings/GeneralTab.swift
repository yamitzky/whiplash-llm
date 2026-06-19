import SwiftUI
import ServiceManagement
import KeyboardShortcuts

struct GeneralTab: View {
    @Bindable var settingsStore: SettingsStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("キーボードショートカット") {
                HStack {
                    Text("新規入力")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .newInput)
                }
                HStack {
                    Text("キャプチャを開始")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .capture)
                }
                HStack {
                    Text("クリップボードキャプチャ")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .clipboardCapture)
                }
            }

            Section("起動") {
                Toggle("ログイン時に起動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = !newValue
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
