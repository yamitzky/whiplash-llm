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
