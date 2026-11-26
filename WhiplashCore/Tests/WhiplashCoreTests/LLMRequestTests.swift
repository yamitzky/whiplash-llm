import XCTest
@testable import WhiplashCore

/// 送られた HTTP リクエストを記録し、決まった応答を返す。実際の API には繋がない。
private final class RecordingURLProtocol: URLProtocol {
    struct Recorded {
        let request: URLRequest
        let body: Data
    }

    enum Reply {
        case http(status: Int, body: Data, contentType: String = "application/json")
        case failure(URLError)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [Recorded] = []
    nonisolated(unsafe) static var reply: Reply = .http(status: 400, body: Data(#"{"error":{"message":"stub"}}"#.utf8))

    static func reset(reply: Reply = .http(status: 400, body: Data(#"{"error":{"message":"stub"}}"#.utf8))) {
        lock.withLock {
            recorded = []
            self.reply = reply
        }
    }

    static var requests: [Recorded] { lock.withLock { recorded } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.lock.withLock {
            Self.recorded.append(Recorded(request: request, body: Self.bodyData(of: request)))
            return Self.reply
        }
        switch reply {
        case .http(let status, let body, let contentType):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// URLSession は URLProtocol に本文を httpBody ではなく httpBodyStream で渡す。
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class InMemorySecretStore: SecretStore {
    var values: [String: String] = [:]
    func get(_ account: String) -> String? { values[account] }
    func set(_ value: String, for account: String) { values[account] = value }
    func delete(_ account: String) { values[account] = nil }
}

/// ロールの指示と追加の質問が、プロバイダーの API にどういう形で届くかを確かめる。
@MainActor
final class LLMRequestTests: XCTestCase {
    private let suite = "LLMRequestTests"
    private var defaults: UserDefaults!

    private let rolePrompt = "ROLE-INSTRUCTIONS: 箇条書きで要約する"

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        RecordingURLProtocol.reset()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeService(provider: BackendProvider, modelIdentifier: String) -> (LLMService, UUID) {
        let secrets = InMemorySecretStore()
        secrets.set("test-key", for: "apiKey-\(provider.rawValue)")
        let store = SettingsStore(defaults: defaults, secrets: secrets)
        let model = ModelConfig(name: "stub", provider: provider, modelIdentifier: modelIdentifier)
        store.models = [model]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        return (LLMService(settingsStore: store, transport: URLSession(configuration: config)), model.id)
    }

    /// 応答はスタブのエラーなので生成は失敗する。確かめたいのは送った中身だけ。
    private func sentBody(provider: BackendProvider, modelIdentifier: String, fullText: String) async throws -> String {
        let (service, modelId) = makeService(provider: provider, modelIdentifier: modelIdentifier)
        _ = try? await service.generateStreamingResponse(fullText: fullText, systemPrompt: rolePrompt, modelId: modelId) { _ in }
        let request = try XCTUnwrap(RecordingURLProtocol.requests.first, "リクエストが送られていない")
        return String(decoding: request.body, as: UTF8.self)
    }

    private func jsonObject(_ body: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    private func jsonString(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value) || value is String else { return "" }
        if let string = value as? String { return string }
        let data = try! JSONSerialization.data(withJSONObject: value)
        return String(decoding: data, as: UTF8.self)
    }

    func test_Anthropicではロールの指示をsystemで送りユーザーの発言に混ぜない() async throws {
        let body = try await sentBody(provider: .anthropic, modelIdentifier: "claude-haiku-4-5", fullText: "本文")
        print("[LLMRequestTests] anthropic body: \(body)")
        let json = try jsonObject(body)
        XCTAssertTrue(jsonString(json["system"]).contains(rolePrompt), "system に指示が無い: \(body)")
        XCTAssertFalse(jsonString(json["messages"]).contains(rolePrompt), "messages に指示が混ざっている: \(body)")
    }

    func test_Geminiではロールの指示をsystemInstructionで送りユーザーの発言に混ぜない() async throws {
        let body = try await sentBody(provider: .gemini, modelIdentifier: "gemini-2.5-flash", fullText: "本文")
        print("[LLMRequestTests] gemini body: \(body)")
        let json = try jsonObject(body)
        XCTAssertTrue(jsonString(json["systemInstruction"] ?? json["system_instruction"]).contains(rolePrompt), "systemInstruction に指示が無い: \(body)")
        XCTAssertFalse(jsonString(json["contents"]).contains(rolePrompt), "contents に指示が混ざっている: \(body)")
    }

    /// 追加の質問は毎回新しいセッションで送り、前回の応答は CaptureFlow / InputFlow がプロンプト本文に埋め込む。
    /// その本文がそのまま OpenRouter に届くかを、アプリと同じ形の本文で確かめる。
    func test_OpenRouterの追加の質問で前回の応答が送られる() async throws {
        let previousAnswer = "PREVIOUS-ANSWER: 1. 要点A 2. 要点B"
        let followUp = "\("元の本文")\n\n---\n前回の応答:\n\(previousAnswer)\n\n---\n追加指示: もっと短く"
        let body = try await sentBody(provider: .openResponses, modelIdentifier: "openai/gpt-4o-mini", fullText: followUp)
        print("[LLMRequestTests] openResponses body: \(body)")
        let json = try jsonObject(body)
        XCTAssertTrue(jsonString(json["input"]).contains("PREVIOUS-ANSWER"), "前回の応答が input に無い: \(body)")
        XCTAssertTrue(jsonString(json).contains(rolePrompt), "ロールの指示がどこにも無い: \(body)")
    }

    /// iOS の裏から戻ったときのやり直しは、接続断を URLError で見分けている。ライブラリの通信層を通しても見分けられるか。
    func test_通信層が接続断を包んでもやり直しの判定で接続断とみなす() async throws {
        RecordingURLProtocol.reset(reply: .failure(URLError(.networkConnectionLost)))
        let (service, modelId) = makeService(provider: .anthropic, modelIdentifier: "claude-haiku-4-5")
        do {
            _ = try await service.generateStreamingResponse(fullText: "本文", systemPrompt: rolePrompt, modelId: modelId) { _ in }
            XCTFail("接続断なのに成功した")
        } catch {
            print("[LLMRequestTests] connection lost error: \(String(reflecting: error))")
            XCTAssertTrue(InterruptedGeneration.isConnectionInterruption(error), "接続断とみなされない: \(String(reflecting: error))")
        }
    }

    // MARK: - thinking の表示

    private func streamedText(provider: BackendProvider, reply: RecordingURLProtocol.Reply) async throws -> String {
        RecordingURLProtocol.reset(reply: reply)
        let (service, modelId) = makeService(provider: provider, modelIdentifier: "local-model")
        return try await service.generateStreamingResponse(fullText: "本文", systemPrompt: rolePrompt, modelId: modelId) { _ in }.text
    }

    func test_LMStudioのreasoning_contentをthinkingとして表示する() async throws {
        let chunks = [
            #"{"id":"c1","object":"chat.completion.chunk","created":0,"model":"local-model","choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"THINK-TEXT"}}]}"#,
            #"{"id":"c1","object":"chat.completion.chunk","created":0,"model":"local-model","choices":[{"index":0,"delta":{"content":"ANSWER-TEXT"}}]}"#,
            #"{"id":"c1","object":"chat.completion.chunk","created":0,"model":"local-model","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
        ]
        let sse = chunks.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
        let text = try await streamedText(provider: .lmStudio, reply: .http(status: 200, body: Data(sse.utf8), contentType: "text/event-stream"))
        XCTAssertEqual(text, "<thinking>THINK-TEXT</thinking>\n\nANSWER-TEXT")
    }

    func test_Ollamaのthinkingをthinkingとして表示する() async throws {
        let lines = [
            #"{"model":"local-model","created_at":"2026-01-01T00:00:00Z","message":{"role":"assistant","content":"","thinking":"THINK-TEXT"},"done":false}"#,
            #"{"model":"local-model","created_at":"2026-01-01T00:00:00Z","message":{"role":"assistant","content":"ANSWER-TEXT"},"done":false}"#,
            #"{"model":"local-model","created_at":"2026-01-01T00:00:00Z","message":{"role":"assistant","content":""},"done":true}"#,
        ]
        let body = lines.joined(separator: "\n") + "\n"
        let text = try await streamedText(provider: .ollama, reply: .http(status: 200, body: Data(body.utf8), contentType: "application/x-ndjson"))
        XCTAssertEqual(text, "<thinking>THINK-TEXT</thinking>\n\nANSWER-TEXT")
    }
}
