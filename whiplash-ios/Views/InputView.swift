import SwiftUI
import PhotosUI
import WhiplashCore

struct InputView: View {
    @Bindable var flow: InputFlow
    let roleStore: RoleStore
    let settingsStore: SettingsStore

    @State private var inputText = ""
    @State private var streamingResult: StreamingResult?
    @State private var showResult = false
    @State private var showCamera = false
    @State private var photoSelection: PhotosPickerItem?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if flow.hasContent || !inputText.isEmpty {
                    readyState
                } else {
                    emptyState
                }
            }
            .padding()
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

            HStack(spacing: 12) {
                PhotosPicker(selection: $photoSelection, matching: .screenshots) {
                    Label("スクショを選ぶ", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                PasteButton(payloadType: String.self) { strings in
                    if let text = strings.first, !text.isEmpty {
                        flow.addTextAttachment(text)
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

            // Role grid — the main action
            roleGrid

            // Add more
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
            showResult = true
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
            showResult = true
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
