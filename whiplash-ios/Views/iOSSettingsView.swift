import SwiftUI
import WhiplashCore

struct iOSSettingsView: View {
    @Bindable var roleStore: RoleStore
    @Bindable var settingsStore: SettingsStore

    var body: some View {
        List {
            // MARK: - Roles
            Section {
                ForEach(roleStore.roles) { role in
                    NavigationLink {
                        RoleEditorView(role: Binding(
                            get: { roleStore.roles.first(where: { $0.id == role.id }) ?? role },
                            set: { roleStore.update($0) }
                        ), settingsStore: settingsStore)
                    } label: {
                        HStack(spacing: 8) {
                            Text(role.icon)
                            Text(role.name)
                        }
                    }
                }
                .onMove { from, to in
                    roleStore.move(fromOffsets: from, toOffset: to)
                }
                .onDelete { indexSet in
                    for i in indexSet {
                        roleStore.delete(roleStore.roles[i])
                    }
                }

                Button {
                    let newRole = Role(
                        name: "新しいRole",
                        icon: "⚡",
                        systemPrompt: "",
                        responsePatterns: [.richMessage]
                    )
                    roleStore.add(newRole)
                } label: {
                    Label("新規Role", systemImage: "plus")
                }
            } header: {
                Text("ロール")
            }

            // MARK: - Providers
            Section {
                ForEach(activeProviders, id: \.self) { provider in
                    NavigationLink {
                        ProviderSettingView(provider: provider, settingsStore: settingsStore)
                    } label: {
                        HStack {
                            Text(provider.displayName)
                            Spacer()
                            if provider.requiresAPIKey {
                                if settingsStore.apiKey(for: provider) != nil {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                } else {
                                    Image(systemName: "exclamationmark.circle")
                                        .foregroundStyle(.orange)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("接続設定")
            }

            // MARK: - Models
            Section {
                ForEach(settingsStore.models) { model in
                    HStack {
                        if model.id == settingsStore.defaultModelId {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                                .font(.caption)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name)
                                .font(.body)
                            HStack(spacing: 4) {
                                Text(model.provider.displayName)
                                if model.thinking != .off {
                                    Text("(\(model.thinking.label))")
                                        .foregroundStyle(.orange)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.id != settingsStore.defaultModelId {
                            Button("デフォルト") {
                                settingsStore.defaultModelId = model.id
                            }
                            .font(.caption)
                        }
                    }
                }
                .onDelete { indexSet in
                    for i in indexSet {
                        settingsStore.deleteModel(id: settingsStore.models[i].id)
                    }
                }

                NavigationLink {
                    AddModelView(settingsStore: settingsStore)
                } label: {
                    Label("モデルを追加", systemImage: "plus")
                }
            } header: {
                Text("モデル一覧")
            }

            // MARK: - Input
            Section {
                Toggle("Enterで送信", isOn: $settingsStore.enterToSend)
            } header: {
                Text("入力")
            }
        }
    }

    private var activeProviders: [BackendProvider] {
        let providers = Set(settingsStore.models.map(\.provider))
        return BackendProvider.allCases.filter { providers.contains($0) }
    }
}

// MARK: - Role Editor

private struct RoleEditorView: View {
    @Binding var role: Role
    var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section("基本設定") {
                HStack {
                    Text("アイコン")
                    Spacer()
                    TextField("", text: $role.icon)
                        .frame(width: 50)
                        .multilineTextAlignment(.center)
                }
                HStack {
                    Text("Role名")
                    Spacer()
                    TextField("", text: $role.name)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("システムプロンプト") {
                TextEditor(text: $role.systemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 150)
            }

            Section("応答パターン") {
                ForEach(ResponsePattern.allCases, id: \.self) { pattern in
                    Toggle(isOn: Binding(
                        get: { role.responsePatterns.contains(pattern) },
                        set: { enabled in
                            if enabled {
                                if !role.responsePatterns.contains(pattern) {
                                    role.responsePatterns.append(pattern)
                                }
                            } else {
                                role.responsePatterns.removeAll { $0 == pattern }
                            }
                        }
                    )) {
                        HStack {
                            Text(pattern.icon)
                            Text(pattern.label)
                        }
                    }
                }
            }

            Section("使用モデル") {
                Picker("モデル", selection: $role.modelId) {
                    Text("デフォルト (\(settingsStore.defaultModel?.name ?? "未設定"))")
                        .tag(nil as UUID?)
                    ForEach(settingsStore.models) { model in
                        Text("\(model.name)  (\(model.provider.displayName))")
                            .tag(model.id as UUID?)
                    }
                }
            }
        }
        .navigationTitle(role.name)
    }
}

// MARK: - Provider Settings

private struct ProviderSettingView: View {
    let provider: BackendProvider
    @Bindable var settingsStore: SettingsStore
    @State private var apiKey: String = ""
    @State private var endpointText: String = ""

    var body: some View {
        Form {
            if provider == .foundationModels {
                Section {
                    Text("オンデバイスモデル。追加設定は不要です。")
                        .foregroundStyle(.secondary)
                }
            }

            if provider.requiresAPIKey {
                Section("API Key") {
                    SecureField("sk-...", text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: apiKey) {
                            settingsStore.setAPIKey(apiKey.isEmpty ? nil : apiKey, for: provider)
                        }
                }
            }

            if provider != .foundationModels {
                Section("エンドポイント") {
                    TextField(provider.defaultEndpoint.absoluteString, text: $endpointText)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: endpointText) {
                            settingsStore.setEndpoint(
                                endpointText.isEmpty ? nil : URL(string: endpointText),
                                for: provider
                            )
                        }

                    if !endpointText.isEmpty {
                        Button("デフォルトに戻す") {
                            endpointText = ""
                            settingsStore.setEndpoint(nil, for: provider)
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle(provider.displayName)
        .onAppear {
            apiKey = settingsStore.apiKey(for: provider) ?? ""
            endpointText = settingsStore.connection(for: provider).endpoint?.absoluteString ?? ""
        }
    }
}

// MARK: - Add Model

private struct AddModelView: View {
    var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var provider: BackendProvider = .anthropic
    @State private var modelId = ""
    @State private var thinkingMode: ThinkingMode = .off
    @State private var budget = "4096"

    enum ThinkingMode: String, CaseIterable {
        case off = "オフ"
        case auto = "自動"
        case budget = "Budget指定"
    }

    var body: some View {
        Form {
            Section {
                Picker("プロバイダー", selection: $provider) {
                    ForEach(BackendProvider.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                TextField("表示名", text: $name)
                TextField("モデルID（例: claude-sonnet-4-5-20250929）", text: $modelId)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            if provider.supportsThinking {
                Section("Thinking") {
                    Picker("モード", selection: $thinkingMode) {
                        ForEach(ThinkingMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    if thinkingMode == .budget {
                        TextField("トークン数", text: $budget)
                            .keyboardType(.numberPad)
                    }
                }
            }

            Section {
                Button("追加") {
                    let thinking: ThinkingConfig = switch thinkingMode {
                    case .off: .off
                    case .auto: .auto
                    case .budget: .budget(Int(budget) ?? 4096)
                    }
                    let model = ModelConfig(
                        name: name.isEmpty ? modelId : name,
                        provider: provider,
                        modelIdentifier: modelId,
                        thinking: thinking
                    )
                    settingsStore.addModel(model)
                    dismiss()
                }
                .disabled(modelId.isEmpty)
            }
        }
        .navigationTitle("モデルを追加")
    }
}
