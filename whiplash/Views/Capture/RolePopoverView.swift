import SwiftUI
import AppKit

// MARK: - Role Selection View

struct RoleSelectionView: View {
    let roles: [Role]
    let onSelect: (Role, String, [Attachment]) -> Void
    let onFreeQuestion: (String, [Attachment]) -> Void
    let onCancel: () -> Void

    @State private var inputText = ""
    @State private var highlightedIndex = 0
    @State private var attachments: [Attachment]
    @State private var mentionedRole: Role?
    @FocusState private var isInputFocused: Bool

    init(
        roles: [Role],
        initialAttachments: [Attachment] = [],
        onSelect: @escaping (Role, String, [Attachment]) -> Void,
        onFreeQuestion: @escaping (String, [Attachment]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.roles = roles
        self._attachments = State(initialValue: initialAttachments)
        self.onSelect = onSelect
        self.onFreeQuestion = onFreeQuestion
        self.onCancel = onCancel
    }

    // MARK: - @ autocomplete

    private var mentionQuery: (query: String, atIndex: String.Index)? {
        guard let atIdx = inputText.lastIndex(of: "@") else { return nil }
        let afterAt = inputText.index(after: atIdx)
        let rest = inputText[afterAt...]
        // Only active if @ is not followed by a space (still typing the mention)
        if let spaceIdx = rest.firstIndex(of: " "), spaceIdx < rest.endIndex {
            return nil
        }
        return (String(rest), atIdx)
    }

    private var suggestions: [Role] {
        guard let mq = mentionQuery else { return [] }
        if mq.query.isEmpty { return roles }
        return roles.filter { $0.name.localizedCaseInsensitiveContains(mq.query) }
    }

    private var showingSuggestions: Bool { !suggestions.isEmpty }

    // MARK: - Chips (attachments + mentioned role)

    private var hasChips: Bool { !attachments.isEmpty || mentionedRole != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Chips row: attachments + mentioned role
            if hasChips {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        // Mentioned role chip
                        if let role = mentionedRole {
                            RoleChipView(role: role) {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    mentionedRole = nil
                                }
                            }
                        }
                        // Attachment chips
                        ForEach(attachments) { attachment in
                            AttachmentChipView(attachment: attachment) {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    attachments.removeAll { $0.id == attachment.id }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }

            // Input row
            HStack(spacing: 6) {
                Button {
                    addFromClipboard()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("クリップボードから添付")

                TextField("@role 追加指示 / 質問", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...3)
                    .focused($isInputFocused)
                    .onSubmit { handleSubmit() }
                    .onKeyPress(.delete) {
                        if inputText.isEmpty {
                            if mentionedRole != nil {
                                withAnimation(.easeOut(duration: 0.15)) { mentionedRole = nil }
                                return .handled
                            }
                            if !attachments.isEmpty {
                                withAnimation(.easeOut(duration: 0.15)) { attachments.removeLast() }
                                return .handled
                            }
                        }
                        return .ignored
                    }

                Button {
                    handleSubmit()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSubmit ? Color.accentColor : Color.secondary)
                .disabled(!canSubmit)
                .help("送信")
            }
            .padding(10)

            // @ autocomplete suggestions
            if showingSuggestions {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, role in
                            Button {
                                selectMention(role)
                            } label: {
                                HStack(spacing: 4) {
                                    Text(role.icon).font(.system(size: 12))
                                    Text(role.name).font(.system(size: 12))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(index == highlightedIndex ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1))
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }

            Divider()

            // Role list (always all roles)
            VStack(spacing: 2) {
                ForEach(roles) { role in
                    RoleRowView(role: role, isSelected: false)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelect(role, inputText, attachments)
                        }
                }
            }
            .padding(6)
        }
        .frame(width: 320)
        .onAppear { isInputFocused = true }
        .onChange(of: inputText) { _, _ in
            highlightedIndex = 0
        }
        .onKeyPress(.upArrow) {
            guard showingSuggestions else { return .ignored }
            highlightedIndex = max(0, highlightedIndex - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard showingSuggestions else { return .ignored }
            highlightedIndex = min(suggestions.count - 1, highlightedIndex + 1)
            return .handled
        }
        .onExitCommand { onCancel() }
    }

    private var canSubmit: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !attachments.isEmpty
        || mentionedRole != nil
    }

    // MARK: - Actions

    private func selectMention(_ role: Role) {
        mentionedRole = role
        // Remove @query from input
        if let mq = mentionQuery {
            let removeStart = mq.atIndex
            let removeEnd = inputText.endIndex
            inputText.removeSubrange(removeStart..<removeEnd)
            inputText = inputText.trimmingCharacters(in: .whitespaces)
        }
    }

    private func handleSubmit() {
        // If showing @ suggestions, select the highlighted one
        if showingSuggestions {
            let index = min(highlightedIndex, suggestions.count - 1)
            selectMention(suggestions[index])
            return
        }

        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)

        // If a role is mentioned, use it
        if let role = mentionedRole {
            onSelect(role, text, attachments)
            return
        }

        guard !text.isEmpty else { return }
        onFreeQuestion(text, attachments)
    }

    private func addFromClipboard() {
        let pasteboard = NSPasteboard.general
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            withAnimation(.easeOut(duration: 0.15)) {
                attachments.append(Attachment(kind: .text(text)))
            }
            return
        }
        if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
            let tempPath = "/tmp/whiplash-clipboard-\(UUID().uuidString).png"
            let tempURL = URL(fileURLWithPath: tempPath)
            if let imageRep = NSBitmapImageRep(data: imageData),
               let pngData = imageRep.representation(using: .png, properties: [:]) {
                try? pngData.write(to: tempURL)
                withAnimation(.easeOut(duration: 0.15)) {
                    attachments.append(Attachment(kind: .image(tempURL)))
                }
            }
        }
    }
}

// MARK: - Role Chip (for @mentioned role)

struct RoleChipView: View {
    let role: Role
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(role.icon).font(.system(size: 11))
            Text(role.name).font(.system(size: 11, weight: .medium))
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.15))
        .cornerRadius(12)
    }
}

// MARK: - Attachment Chip

struct AttachmentChipView: View {
    let attachment: Attachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(attachment.label)
                .font(.system(size: 11))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12))
        .cornerRadius(12)
    }
}

// MARK: - Role Row

struct RoleRowView: View {
    let role: Role
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(role.icon)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(role.name)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 4) {
                    ForEach(role.responsePatterns, id: \.self) { pattern in
                        Text(pattern.icon)
                            .font(.system(size: 10))
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
        )
    }
}
