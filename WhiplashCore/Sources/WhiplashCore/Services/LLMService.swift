import Foundation
import AnyLanguageModel

public struct LLMResponse: Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public enum LLMError: Error, LocalizedError {
    case providerUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .providerUnavailable(let name):
            return "\(name) はこのデバイスでは利用できません。設定から別のモデルを選択してください。"
        }
    }
}

public final class LLMService: Sendable {
    private let settingsStore: SettingsStore

    // 非ストリーミングや thinking 中はサーバーが生成完了まで無通信になるため、
    // URLSession 既定の 60 秒アイドルタイムアウトでは長い応答が切れる。
    // リトライは同じ重さで再度タイムアウトし課金も二重になるので採用しなかった。
    private static let httpSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    @MainActor
    public func generateResponse(fullText: String, role: Role, additionalInstructions: String? = nil, imageData: [(Data, String)]? = nil) async throws -> LLMResponse {
        let modelConfig = settingsStore.model(for: role.modelId)
        let prompt = buildPrompt(fullText: fullText, additionalInstructions: additionalInstructions)
        print("[LLM] provider: \(modelConfig?.provider.rawValue ?? "?"), model: \(modelConfig?.modelIdentifier ?? "default")")
        let session = try createSession(instructions: role.systemPrompt, modelConfig: modelConfig)
        let options = buildOptions(modelConfig: modelConfig)
        if let imageData, !imageData.isEmpty {
            let images = imageData.map { Transcript.ImageSegment(data: $0.0, mimeType: $0.1) }
            let response = try await session.respond(to: prompt, images: images, options: options)
            return LLMResponse(text: response.content)
        }
        let response = try await session.respond(to: prompt, options: options)
        return LLMResponse(text: response.content)
    }

    @MainActor
    public func generateStreamingResponse(
        fullText: String,
        role: Role,
        additionalInstructions: String? = nil,
        imageData: [(Data, String)]? = nil,
        onPartialResponse: @Sendable @escaping (String) async -> Void
    ) async throws -> LLMResponse {
        try await generateStreamingResponse(
            fullText: fullText,
            systemPrompt: role.systemPrompt,
            modelId: role.modelId,
            additionalInstructions: additionalInstructions,
            imageData: imageData,
            onPartialResponse: onPartialResponse
        )
    }

    @MainActor
    public func generateStreamingResponse(
        fullText: String,
        systemPrompt: String = "",
        modelId: UUID? = nil,
        additionalInstructions: String? = nil,
        imageData: [(Data, String)]? = nil,
        onPartialResponse: @Sendable @escaping (String) async -> Void
    ) async throws -> LLMResponse {
        let modelConfig = settingsStore.model(for: modelId)
        let prompt = buildPrompt(fullText: fullText, additionalInstructions: additionalInstructions)
        print("[LLM] streaming: \(modelConfig?.provider.rawValue ?? "?") / \(modelConfig?.modelIdentifier ?? "default")")
        let session = try createSession(instructions: systemPrompt, modelConfig: modelConfig)
        let options = buildOptions(modelConfig: modelConfig)

        if let imageData, !imageData.isEmpty {
            let images = imageData.map { Transcript.ImageSegment(data: $0.0, mimeType: $0.1) }
            let stream = session.streamResponse(to: prompt, images: images, options: options)
            var finalText = ""
            for try await snapshot in stream {
                finalText = Self.displayText(of: snapshot)
                await onPartialResponse(finalText)
            }
            return LLMResponse(text: finalText)
        }

        let stream = session.streamResponse(to: prompt, options: options)
        var finalText = ""
        for try await snapshot in stream {
            finalText = Self.displayText(of: snapshot)
            await onPartialResponse(finalText)
        }
        return LLMResponse(text: finalText)
    }

    /// 思考過程は本文ではなく transcriptEntries の reasoning として届くので、
    /// UI が切り出している `<thinking>…</thinking>` 形式に組み立て直す。
    static func displayText(of snapshot: LanguageModelSession.ResponseStream<String>.Snapshot) -> String {
        displayText(content: snapshot.content, entries: snapshot.transcriptEntries)
    }

    static func displayText(content: String, entries: some Collection<Transcript.Entry>) -> String {
        let thinking = entries.compactMap { entry -> String? in
            guard case .reasoning(let reasoning) = entry else { return nil }
            return reasoning.segments.compactMap { segment -> String? in
                guard case .text(let text) = segment else { return nil }
                return text.content
            }.joined()
        }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !thinking.isEmpty else { return content }
        return "<thinking>\(thinking)</thinking>\n\n\(content)"
    }

    private func buildPrompt(fullText: String, additionalInstructions: String?) -> String {
        guard let instructions = additionalInstructions, !instructions.isEmpty else {
            return fullText
        }
        return "\(fullText)\n\n---\n追加指示: \(instructions)"
    }

    @MainActor
    private func buildOptions(modelConfig: ModelConfig?) -> GenerationOptions {
        var options = GenerationOptions()
        guard let modelConfig, modelConfig.thinking != .off else { return options }

        switch modelConfig.provider {
        case .anthropic:
            switch modelConfig.thinking {
            case .off: break
            case .auto:
                options[custom: AnthropicLanguageModel.self] = .init(
                    thinking: .init(budgetTokens: 4096)
                )
            case .budget(let n):
                options[custom: AnthropicLanguageModel.self] = .init(
                    thinking: .init(budgetTokens: n)
                )
            }
        case .gemini:
            switch modelConfig.thinking {
            case .off:
                options[custom: GeminiLanguageModel.self] = .init(thinking: .disabled)
            case .auto:
                options[custom: GeminiLanguageModel.self] = .init(thinking: .dynamic)
            case .budget(let n):
                options[custom: GeminiLanguageModel.self] = .init(thinking: .budget(n))
            }
        case .openAI, .openResponses:
            switch modelConfig.thinking {
            case .off: break
            case .auto:
                options[custom: OpenAILanguageModel.self] = .init(reasoningEffort: .medium)
            case .budget(let n):
                let effort: OpenAILanguageModel.CustomGenerationOptions.ReasoningEffort
                switch n {
                case ..<1000: effort = .low
                case ..<5000: effort = .medium
                default: effort = .high
                }
                options[custom: OpenAILanguageModel.self] = .init(reasoningEffort: effort)
            }
        default:
            break
        }
        return options
    }

    @MainActor
    private func createSession(instructions: String, modelConfig: ModelConfig?) throws -> LanguageModelSession {
        guard let modelConfig else {
            if #available(macOS 26, iOS 26, *) {
                return LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            }
            throw LLMError.providerUnavailable("Apple Foundation Models")
        }

        let provider = modelConfig.provider
        let endpoint = settingsStore.endpoint(for: provider)
        let apiKey = settingsStore.apiKey(for: provider) ?? ""

        let model: any LanguageModel
        switch provider {
        case .foundationModels:
            if #available(macOS 26, iOS 26, *) {
                model = SystemLanguageModel.default
            } else {
                throw LLMError.providerUnavailable("Apple Foundation Models")
            }
        case .ollama:
            model = OllamaLanguageModel(baseURL: endpoint, model: modelConfig.modelIdentifier, session: Self.httpSession)
        case .lmStudio:
            model = OpenAILanguageModel(baseURL: endpoint, apiKey: "lm-studio", model: modelConfig.modelIdentifier, session: Self.httpSession)
        case .openAI:
            model = OpenAILanguageModel(baseURL: endpoint, apiKey: apiKey, model: modelConfig.modelIdentifier, session: Self.httpSession)
        case .anthropic:
            model = AnthropicLanguageModel(apiKey: apiKey, model: modelConfig.modelIdentifier, session: Self.httpSession)
        case .gemini:
            model = GeminiLanguageModel(apiKey: apiKey, model: modelConfig.modelIdentifier, session: Self.httpSession)
        case .openResponses:
            model = OpenResponsesLanguageModel(baseURL: endpoint, apiKey: apiKey, model: modelConfig.modelIdentifier, session: Self.httpSession)
        }
        return LanguageModelSession(model: model, instructions: instructions)
    }
}
