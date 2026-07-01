import SwiftUI
import WhiplashCore

struct InputView: View {
    @Bindable var flow: InputFlow
    let roleStore: RoleStore
    let settingsStore: SettingsStore

    @State private var inputText = ""
    @State private var streamingResult: StreamingResult?
    @State private var showResult = false

    var body: some View {
        VStack(spacing: 0) {
            // Attachments
            if !flow.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(flow.attachments) { attachment in
                            AttachmentChip(attachment: attachment) {
                                flow.removeAttachment(attachment)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .background(.bar)

                Divider()
            }

            // Input area
            VStack(spacing: 12) {
                TextField("質問やメモを入力（任意）", text: $inputText, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                // Role buttons
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                    ], spacing: 10) {
                        ForEach(roleStore.roles) { role in
                            Button {
                                startProcessing(role: role)
                            } label: {
                                VStack(spacing: 4) {
                                    Text(role.icon)
                                        .font(.title)
                                    Text(role.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(.fill.tertiary)
                                .cornerRadius(12)
                            }
                            .buttonStyle(.plain)
                            .disabled(flow.isProcessing)
                        }

                        // Free question button
                        Button {
                            startFreeQuestion()
                        } label: {
                            VStack(spacing: 4) {
                                Text("⚡")
                                    .font(.title)
                                Text("自由質問")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.fill.tertiary)
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                        .disabled(flow.isProcessing || (inputText.isEmpty && flow.attachments.isEmpty))
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.top, 12)
        }
        .sheet(isPresented: $showResult) {
            if let result = streamingResult {
                ResultView(result: result) {
                    showResult = false
                    flow.clearAttachments()
                    inputText = ""
                }
            }
        }
    }

    private func startProcessing(role: Role) {
        Task {
            let result = await flow.processWithRole(
                role,
                additionalInstructions: inputText,
                settingsStore: settingsStore
            )
            streamingResult = result
            showResult = true
        }
    }

    private func startFreeQuestion() {
        guard !inputText.isEmpty || !flow.attachments.isEmpty else { return }
        Task {
            let result = await flow.processFreeQuestion(
                inputText,
                settingsStore: settingsStore
            )
            streamingResult = result
            showResult = true
        }
    }
}

// MARK: - Attachment Chip

private struct AttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if case .image(let url) = attachment.kind {
                if let uiImage = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            } else {
                Text(attachment.label)
                    .font(.caption)
                    .lineLimit(1)
            }

            Button { onRemove() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(6)
        .background(.fill.quaternary)
        .cornerRadius(8)
    }
}
