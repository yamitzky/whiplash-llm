extension ResponsePattern {
    public var icon: String {
        switch self {
        case .richMessage: "💬"
        case .clipboard: "📋"
        }
    }

    public var label: String {
        switch self {
        case .richMessage: "メッセージボックス"
        case .clipboard: "クリップボードにコピー"
        }
    }
}

extension BackendProvider {
    public var supportsThinking: Bool {
        switch self {
        case .anthropic, .gemini, .openAI, .openResponses: true
        case .foundationModels, .ollama, .lmStudio: false
        }
    }
}

extension ImageInputMode {
    public var label: String {
        switch self {
        case .image: "画像をそのまま送信"
        case .ocr: "テキスト抽出 (OCR)"
        }
    }
}
