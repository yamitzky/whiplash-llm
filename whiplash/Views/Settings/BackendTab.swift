import SwiftUI

struct BackendTab: View {
    @Bindable var settingsStore: SettingsStore

    /// Providers that the user has models registered for
    private var activeProviders: [BackendProvider] {
        let providers = Set(settingsStore.models.map(\.provider))
        return BackendProvider.allCases.filter { providers.contains($0) }
    }

    var body: some View {
        Form {
            // MARK: - Connection settings per provider (only show providers that have models)
            Section("接続設定") {
                ForEach(activeProviders, id: \.self) { provider in
                    DisclosureGroup(provider.displayName) {
                        if provider.requiresAPIKey {
                            LabeledContent("APIキー") {
                                SecureField(
                                    "sk-...",
                                    text: Binding(
                                        get: { settingsStore.apiKey(for: provider) ?? "" },
                                        set: { settingsStore.setAPIKey($0, for: provider) }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 200)
                            }
                        }

                        if provider != .foundationModels {
                            LabeledContent("エンドポイント") {
                                TextField(
                                    provider.defaultEndpoint.absoluteString,
                                    text: Binding(
                                        get: { settingsStore.connection(for: provider).endpoint?.absoluteString ?? "" },
                                        set: { settingsStore.setEndpoint(URL(string: $0), for: provider) }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 200)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            }
                        }

                        if !provider.requiresAPIKey && provider == .foundationModels {
                            Text("オンデバイスモデル。追加設定は不要です。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // MARK: - Model list (all providers mixed)
            Section("モデル一覧") {
                ForEach(settingsStore.models) { model in
                    HStack {
                        if model.id == settingsStore.defaultModelId {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                                .font(.caption)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name)
                                .fontWeight(.medium)
                            Text("\(model.provider.displayName) / \(model.modelIdentifier)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if model.id != settingsStore.defaultModelId {
                            Button("デフォルト") {
                                settingsStore.defaultModelId = model.id
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }

                        Button {
                            settingsStore.deleteModel(id: model.id)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }

                AddModelButton(settingsStore: settingsStore)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct AddModelButton: View {
    var settingsStore: SettingsStore
    @State private var isAdding = false
    @State private var newName = ""
    @State private var newProvider: BackendProvider = .anthropic
    @State private var newModelId = ""

    var body: some View {
        if isAdding {
            VStack(alignment: .leading, spacing: 8) {
                Picker("プロバイダー", selection: $newProvider) {
                    ForEach(BackendProvider.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .frame(width: 300)

                TextField("表示名", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)

                TextField("モデルID", text: $newModelId)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)

                HStack {
                    Button("追加") {
                        let model = ModelConfig(
                            name: newName.isEmpty ? newModelId : newName,
                            provider: newProvider,
                            modelIdentifier: newModelId
                        )
                        settingsStore.addModel(model)
                        isAdding = false
                        newName = ""
                        newModelId = ""
                    }
                    .disabled(newModelId.isEmpty)

                    Button("キャンセル") {
                        isAdding = false
                        newName = ""
                        newModelId = ""
                    }
                }
            }
            .padding(.vertical, 4)
        } else {
            Button {
                isAdding = true
            } label: {
                Label("モデルを追加", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }
}
