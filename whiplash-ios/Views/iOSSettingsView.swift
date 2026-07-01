import SwiftUI
import WhiplashCore

struct iOSSettingsView: View {
    let roleStore: RoleStore
    @Bindable var settingsStore: SettingsStore

    var body: some View {
        List {
            Section("AI バックエンド") {
                ForEach(BackendProvider.allCases, id: \.self) { provider in
                    if provider.requiresAPIKey {
                        NavigationLink {
                            ProviderSettingView(provider: provider, settingsStore: settingsStore)
                        } label: {
                            HStack {
                                Text(provider.displayName)
                                Spacer()
                                if settingsStore.apiKey(for: provider) != nil {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
            }

            Section("デフォルトモデル") {
                Picker("モデル", selection: $settingsStore.defaultModelId) {
                    ForEach(settingsStore.models) { model in
                        Text(model.name).tag(Optional(model.id))
                    }
                }
            }

            Section("入力") {
                Toggle("Enterで送信", isOn: $settingsStore.enterToSend)
            }
        }
    }
}

private struct ProviderSettingView: View {
    let provider: BackendProvider
    @Bindable var settingsStore: SettingsStore
    @State private var apiKey: String = ""

    var body: some View {
        Form {
            Section("API Key") {
                SecureField("API Key", text: $apiKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button("保存") {
                    settingsStore.setAPIKey(apiKey.isEmpty ? nil : apiKey, for: provider)
                }
            }
        }
        .navigationTitle(provider.displayName)
        .onAppear {
            apiKey = settingsStore.apiKey(for: provider) ?? ""
        }
    }
}
