import SwiftUI

struct ResultView: View {
    @Bindable var result: StreamingResult
    let onDismiss: () -> Void

    @State private var showRawText = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if result.isStreaming && result.text.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("処理中...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else if let error = result.error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(error)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    VStack(alignment: .leading) {
                        Text(result.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if result.isStreaming {
                            ProgressView()
                                .padding(.top, 4)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("結果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { onDismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = result.text
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(result.text.isEmpty)
                }
            }
        }
    }
}
