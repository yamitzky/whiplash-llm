import SwiftUI
import MarkdownView

struct RichMessageView: View {
    let streamingText: StreamingText
    let onCopy: () -> Void
    let onRegenerate: () -> Void
    let onFollowUp: (String) -> Void

    @State private var followUpText: String = ""
    @State private var showRawText: Bool = false
    @FocusState private var isFollowUpFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    if let error = streamingText.error {
                        Text("エラー: \(error)")
                            .foregroundStyle(.red)
                    } else if streamingText.text.isEmpty && streamingText.isStreaming {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("応答を生成中...")
                                .foregroundStyle(.secondary)
                        }
                    } else if showRawText {
                        Text(streamingText.text)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        MarkdownView(streamingText.text)
                            .textSelection(.enabled)
                    }
                }
                .font(.system(size: 13))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }

            Divider()

            HStack(spacing: 8) {
                TextField("追加の指示を入力...", text: $followUpText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($isFollowUpFocused)
                    .disabled(streamingText.isStreaming)
                    .onSubmit {
                        submitFollowUp()
                    }

                if streamingText.isStreaming && !streamingText.text.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    showRawText.toggle()
                } label: {
                    Image(systemName: showRawText ? "doc.richtext" : "doc.plaintext")
                }
                .help(showRawText ? "Markdown表示" : "素テキスト表示")

                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                }
                .help("コピー")
                .disabled(streamingText.isStreaming || streamingText.text.isEmpty)

                Button(action: onRegenerate) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("再生成")
                .disabled(streamingText.isStreaming)
            }
            .padding(10)
        }
        .frame(minWidth: 300, minHeight: 200)
    }

    private func submitFollowUp() {
        let text = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        followUpText = ""
        onFollowUp(text)
    }
}
