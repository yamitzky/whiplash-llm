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
        let response = try await session.respond(to: prompt)
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

        let stream = session.streamResponse(to: prompt)
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
