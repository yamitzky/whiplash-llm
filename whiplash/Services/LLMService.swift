import Foundation
import AnyLanguageModel

struct LLMResponse {
    let text: String
}

final class LLMService {
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func generateResponse(fullText: String, role: Role, additionalInstructions: String? = nil) async throws -> LLMResponse {
        let modelConfig = settingsStore.model(for: role.modelId)
        let prompt = buildPrompt(fullText: fullText, additionalInstructions: additionalInstructions)
        print("[LLM] provider: \(modelConfig?.provider.rawValue ?? "?"), model: \(modelConfig?.modelIdentifier ?? "default")")
        let session = createSession(instructions: role.systemPrompt, modelConfig: modelConfig)
        let options = buildOptions(modelConfig: modelConfig)
        let response = try await session.respond(to: prompt, options: options)
        return LLMResponse(text: response.content)
    }

    func generateStreamingResponse(
        fullText: String,
        role: Role,
        additionalInstructions: String? = nil,
        onPartialResponse: @Sendable @escaping (String) async -> Void
    ) async throws -> LLMResponse {
        try await generateStreamingResponse(
            fullText: fullText,
            systemPrompt: role.systemPrompt,
            modelId: role.modelId,
            additionalInstructions: additionalInstructions,
            onPartialResponse: onPartialResponse
        )
    }

    func generateStreamingResponse(
        fullText: String,
        systemPrompt: String = "",
        modelId: UUID? = nil,
        additionalInstructions: String? = nil,
        onPartialResponse: @Sendable @escaping (String) async -> Void
    ) async throws -> LLMResponse {
        let modelConfig = settingsStore.model(for: modelId)
        let prompt = buildPrompt(fullText: fullText, additionalInstructions: additionalInstructions)
        print("[LLM] streaming: \(modelConfig?.provider.rawValue ?? "?") / \(modelConfig?.modelIdentifier ?? "default")")
        let session = createSession(instructions: systemPrompt, modelConfig: modelConfig)
        let options = buildOptions(modelConfig: modelConfig)

        let stream = session.streamResponse(to: prompt, options: options)
        var finalText = ""
        for try await snapshot in stream {
            finalText = snapshot.content
            await onPartialResponse(finalText)
        }
        return LLMResponse(text: finalText)
    }

    private func buildPrompt(fullText: String, additionalInstructions: String?) -> String {
        guard let instructions = additionalInstructions, !instructions.isEmpty else {
            return fullText
        }
        return "\(fullText)\n\n---\n追加指示: \(instructions)"
    }

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

    private func createSession(instructions: String, modelConfig: ModelConfig?) -> LanguageModelSession {
        guard let modelConfig else {
            return LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        }

        let provider = modelConfig.provider
        let endpoint = settingsStore.endpoint(for: provider)
        let apiKey = settingsStore.apiKey(for: provider) ?? ""

        let model: any LanguageModel = switch provider {
        case .foundationModels:
            SystemLanguageModel.default
        case .ollama:
            OllamaLanguageModel(baseURL: endpoint, model: modelConfig.modelIdentifier)
        case .lmStudio:
            OpenAILanguageModel(baseURL: endpoint, apiKey: "lm-studio", model: modelConfig.modelIdentifier)
        case .openAI:
            OpenAILanguageModel(baseURL: endpoint, apiKey: apiKey, model: modelConfig.modelIdentifier)
        case .anthropic:
            AnthropicLanguageModel(apiKey: apiKey, model: modelConfig.modelIdentifier)
        case .gemini:
            GeminiLanguageModel(apiKey: apiKey, model: modelConfig.modelIdentifier)
        case .openResponses:
            OpenResponsesLanguageModel(baseURL: endpoint, apiKey: apiKey, model: modelConfig.modelIdentifier)
        }
        return LanguageModelSession(model: model, instructions: instructions)
    }
}
