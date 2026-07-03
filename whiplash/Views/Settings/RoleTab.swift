import SwiftUI
import WhiplashCore

struct RoleTab: View {
    @Bindable var roleStore: RoleStore
    var settingsStore: SettingsStore
    @State private var selectedRoleID: UUID?

    private var selectedRole: Binding<Role>? {
        guard let id = selectedRoleID,
              let index = roleStore.roles.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return Binding(
            get: { roleStore.roles[index] },
            set: { roleStore.update($0) }
        )
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedRoleID) {
                    ForEach(roleStore.roles) { role in
                        HStack(spacing: 8) {
                            Text(role.icon)
                            Text(role.name)
                                .lineLimit(1)
                        }
                        .contextMenu {
                            Button("削除", role: .destructive) {
                                roleStore.delete(role)
                                if selectedRoleID == role.id {
                                    selectedRoleID = roleStore.roles.first?.id
                                }
                            }
                        }
                    }
                    .onMove { from, to in
                        roleStore.move(fromOffsets: from, toOffset: to)
                    }
                }
                .listStyle(.sidebar)

                Divider()

                Button {
                    let newRole = Role(
                        name: "新しいRole",
                        icon: "⚡",
                        systemPrompt: "",
                        responsePatterns: [.richMessage]
                    )
                    roleStore.add(newRole)
                    selectedRoleID = newRole.id
                } label: {
                    Label("新規Role", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 180, maxWidth: 220)

            if let binding = selectedRole {
                RoleEditorView(role: binding, settingsStore: settingsStore)
            } else {
                ContentUnavailableView("Roleを選択してください", systemImage: "bolt.circle")
            }
        }
        .onAppear {
            if selectedRoleID == nil {
                selectedRoleID = roleStore.roles.first?.id
            }
        }
    }
}

struct RoleEditorView: View {
    @Binding var role: Role
    var settingsStore: SettingsStore
    @FocusState private var iconFieldFocused: Bool

    var body: some View {
        Form {
            Section("基本設定") {
                LabeledContent("アイコン") {
                    HStack(spacing: 4) {
                        TextField("", text: $role.icon)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                            .focused($iconFieldFocused)
                        Button {
                            iconFieldFocused = true
                            DispatchQueue.main.async {
                                NSApp.orderFrontCharacterPalette(nil)
                            }
                        } label: {
                            Image(systemName: "face.smiling")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                LabeledContent("Role名") {
                    TextField("", text: $role.name)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section("システムプロンプト") {
                TextEditor(text: $role.systemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
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
        .formStyle(.grouped)
        .padding()
    }
}

