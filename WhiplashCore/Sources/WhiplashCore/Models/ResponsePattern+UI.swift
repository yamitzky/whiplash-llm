extension ResponsePattern {
    public var icon: String {
        switch self {
        case .richMessage: "💬"
        case .clipboard: "📋"
        case .overlay: "🔤"
        }
    }

    public var label: String {
        switch self {
        case .richMessage: "メッセージボックス"
        case .clipboard: "クリップボードにコピー"
        case .overlay: "元の文章に重ねて表示"
        }
    }

    /// 重ねるかどうかは送るときに選ぶ。ロールに結びつけると同じロールでボックスと使い分けられない。
    /// overlay は以前のビルドが保存したデータを読むためだけに残している。
    public static var selectableCases: [ResponsePattern] {
        allCases.filter { $0 != .overlay }
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
