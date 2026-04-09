import Foundation

// MARK: - Provider

enum BackendProvider: String, Codable, CaseIterable {
    case foundationModels
    case ollama
    case lmStudio
    case openAI
    case anthropic
    case gemini
    case openResponses

    var displayName: String {
        switch self {
        case .foundationModels: "Apple Foundation Models"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .openResponses: "Open Responses"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .foundationModels, .ollama, .lmStudio: false
        case .openAI, .anthropic, .gemini, .openResponses: true
        }
    }

    var defaultEndpoint: URL {
        switch self {
        case .foundationModels: URL(string: "local://foundation-models")!
        case .ollama: URL(string: "http://localhost:11434")!
        case .lmStudio: URL(string: "http://localhost:1234")!
        case .openAI: URL(string: "https://api.openai.com/v1/")!
        case .anthropic: URL(string: "https://api.anthropic.com/")!
        case .gemini: URL(string: "https://generativelanguage.googleapis.com/")!
        case .openResponses: URL(string: "https://openrouter.ai/api/v1/")!
        }
    }
}

// MARK: - Provider Connection (per-provider credentials & endpoint)

struct ProviderConnection: Codable, Equatable {
    var apiKey: String?
    var endpoint: URL?
}

// MARK: - Model Config (self-contained: knows its own provider)

// MARK: - Thinking Config

enum ThinkingConfig: Codable, Equatable {
    case off
    case auto
    case budget(Int)

    var label: String {
        switch self {
        case .off: "オフ"
        case .auto: "自動"
        case .budget(let n): "Budget: \(n)"
        }
    }
}

struct ModelConfig: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var provider: BackendProvider
    var modelIdentifier: String
    var thinking: ThinkingConfig

    init(id: UUID = UUID(), name: String, provider: BackendProvider, modelIdentifier: String, thinking: ThinkingConfig = .off) {
        self.id = id
        self.name = name
        self.provider = provider
        self.modelIdentifier = modelIdentifier
        self.thinking = thinking
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        provider = try container.decode(BackendProvider.self, forKey: .provider)
        modelIdentifier = try container.decode(String.self, forKey: .modelIdentifier)
        thinking = try container.decodeIfPresent(ThinkingConfig.self, forKey: .thinking) ?? .off
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, provider, modelIdentifier, thinking
    }

    static let builtinDefaults: [ModelConfig] = [
        // Apple
        ModelConfig(name: "Foundation Models", provider: .foundationModels, modelIdentifier: "default"),
        // Anthropic
        ModelConfig(name: "Claude Haiku", provider: .anthropic, modelIdentifier: "claude-haiku-4-5-20251001"),
        ModelConfig(name: "Claude Sonnet", provider: .anthropic, modelIdentifier: "claude-sonnet-4-5-20250929"),
        ModelConfig(name: "Claude Opus", provider: .anthropic, modelIdentifier: "claude-opus-4-5-20250929"),
        // OpenAI
        ModelConfig(name: "GPT-4o mini", provider: .openAI, modelIdentifier: "gpt-4o-mini"),
        ModelConfig(name: "GPT-4o", provider: .openAI, modelIdentifier: "gpt-4o"),
        // Gemini
        ModelConfig(name: "Gemini 2.5 Flash", provider: .gemini, modelIdentifier: "gemini-2.5-flash"),
        ModelConfig(name: "Gemini 2.5 Pro", provider: .gemini, modelIdentifier: "gemini-2.5-pro"),
        // Local
        ModelConfig(name: "Llama 3.2 (Ollama)", provider: .ollama, modelIdentifier: "llama3.2"),
    ]
}
