import SwiftUI
import PhotosUI
import WhiplashCore

struct InputView: View {
    @Bindable var flow: InputFlow
    let roleStore: RoleStore
    let settingsStore: SettingsStore

    @State private var inputText = ""
    @State private var streamingResult: StreamingResult?
    @State private var photoSelection: PhotosPickerItem?
    @State private var followUpText = ""

    private var isShowingResult: Bool { streamingResult != nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let result = streamingResult {
                    resultState(result)
                } else if flow.hasContent || !inputText.isEmpty {
                    readyState
                } else {
                    emptyState
                }
            }
            .padding()
        }
        .animation(.default, value: isShowingResult)
        .onChange(of: photoSelection) {
            if let item = photoSelection {
                loadPhoto(item)
                photoSelection = nil
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("テキストや画像を追加して\nAIに処理してもらおう")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.top, 32)

                Text("スクショを撮ってからこのアプリを開くと、自動で読み込まれます")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            if flow.hasNewClipboard {
                VStack(spacing: 8) {
                    Text("新しいコピーがあります")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    PasteButton(payloadType: String.self) { strings in
                        if let text = strings.first, !text.isEmpty {
                            flow.addTextAttachment(text)
                            flow.clipboardConsumed()
                        }
                    }
                    .buttonBorderShape(.roundedRectangle)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.blue.opacity(0.08))
                .cornerRadius(12)
            }

            HStack(spacing: 12) {
                PhotosPicker(selection: $photoSelection, matching: .screenshots) {
                    Label("スクショを選ぶ", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                PasteButton(payloadType: String.self) { strings in
                    if let text = strings.first, !text.isEmpty {
                        flow.addTextAttachment(text)
                        flow.clipboardConsumed()
                    }
                }
            }

            TextField("直接入力する...", text: $inputText, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)

            if !inputText.isEmpty {
                roleGrid
            }
        }
    }

    // MARK: - Ready State (content is present)

    private var readyState: some View {
        VStack(spacing: 16) {
            ForEach(flow.attachments) { attachment in
                attachmentCard(attachment)
            }

            TextField("追加の指示（任意）", text: $inputText, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)

            roleGrid

            HStack(spacing: 12) {
                PhotosPicker(selection: $photoSelection, matching: .images) {
                    Label("画像を追加", systemImage: "photo.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }
        }
    }

    // MARK: - Result State (inline, no sheet)

    private func resultState(_ result: StreamingResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if result.isStreaming && result.text.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("処理中...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else if let error = result.error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                if let thinking = result.thinkingText, !thinking.isEmpty {
                    DisclosureGroup("思考過程") {
                        Text(thinking)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10)
                    .background(.fill.quaternary)
                    .cornerRadius(8)
                }

                if result.responseText.isEmpty && result.isStreaming {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("思考中...")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(result.responseText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if result.isStreaming && !result.responseText.isEmpty {
                    ProgressView()
                        .padding(.top, 4)
                }
            }

            if !result.isStreaming {
                // Follow-up input
                HStack(spacing: 8) {
                    TextField("追加の指示...", text: $followUpText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submitFollowUp(previousResponse: result.text) }

                    Button {
                        submitFollowUp(previousResponse: result.text)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                    }
                    .disabled(followUpText.isEmpty)
                }

                // Action buttons
                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = result.text
                    } label: {
                        Label("コピー", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(result.text.isEmpty)

                    Button {
                        if let newResult = flow.regenerate() {
                            streamingResult = newResult
                        }
                    } label: {
                        Label("再生成", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    Button {
                        streamingResult = nil
                        flow.clearAttachments()
                        inputText = ""
                        followUpText = ""
                    } label: {
                        Label("新規", systemImage: "plus.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Components

    private func attachmentCard(_ attachment: Attachment) -> some View {
        HStack(alignment: .top) {
            Group {
                switch attachment.kind {
                case .image(let url):
                    if let uiImage = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                case .text(let text):
                    Text(text)
                        .font(.caption)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.fill.quaternary)
                        .cornerRadius(8)
                }
            }

            Button { flow.removeAttachment(attachment) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var roleGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
        ], spacing: 10) {
            ForEach(roleStore.roles) { role in
                Button { startProcessing(role: role) } label: {
                    HStack(spacing: 6) {
                        Text(role.icon)
                        Text(role.name)
                            .font(.subheadline.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.blue)
                    .foregroundStyle(.white)
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .disabled(flow.isProcessing)
            }

            if !inputText.isEmpty || flow.hasContent {
                Button { startFreeQuestion() } label: {
                    HStack(spacing: 6) {
                        Text("⚡")
                        Text("質問する")
                            .font(.subheadline.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.orange)
                    .foregroundStyle(.white)
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .disabled(flow.isProcessing)
            }
        }
    }

    // MARK: - Actions

    private func startProcessing(role: Role) {
        Task {
            let result = await flow.processWithRole(
                role,
                additionalInstructions: inputText,
                settingsStore: settingsStore
            )
            streamingResult = result
        }
    }

    private func startFreeQuestion() {
        guard !inputText.isEmpty || flow.hasContent else { return }
        Task {
            let result = await flow.processFreeQuestion(
                inputText,
                settingsStore: settingsStore
            )
            streamingResult = result
        }
    }

    private func submitFollowUp(previousResponse: String) {
        let text = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        followUpText = ""
        if let newResult = flow.followUp(text, previousResponse: previousResponse) {
            streamingResult = newResult
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            flow.addImageAttachment(image)
        }
    }
}
