import XCTest
@testable import WhiplashCore

/// Kotlin の共有コア (shared/) が読む fixture を、今の RoleStore と SettingsStore に書き出させる。
/// 手で書いた JSON では、Swift のエンコーダが実際に出す形(UUID の大文字、`\/` のエスケープ、
/// ThinkingConfig の `{"budget":{"_0":…}}`、辞書を鍵と値の交互の配列にする形)とずれても気づけない。
///
/// 各シナリオは UserDefaults の操作前 (before) と操作後 (after) を書き出す。
/// Kotlin 側は before から同じ操作をして、after と同じ内容になるかを確かめる。
///
/// 普段の `swift test` では何もしない。書き出すときは shared/scripts/export-swift-fixtures.sh を使う。
@MainActor
final class SharedCoreFixtureExport: XCTestCase {
    private var outputDir: URL!
    private let suite = "SharedCoreFixtureExport"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["WHIPLASH_FIXTURE_DIR"] else {
            throw XCTSkip("WHIPLASH_FIXTURE_DIR が無いので fixture を書き出さない")
        }
        outputDir = URL(fileURLWithPath: path)
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: suite)
    }

    // MARK: - 固定の値

    // Kotlin 側で同じ操作を再現できるよう、ID は固定にする。
    private static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "36557CE8-0000-4000-8000-%012d", n))!
    }

    private static let roles: [Role] = [
        Role(id: uuid(1), name: "英訳", icon: "🌐", systemPrompt: "Translate into English.", responsePatterns: [.richMessage]),
        Role(id: uuid(2), name: "コピーする", icon: "📋", systemPrompt: "コピー用", responsePatterns: [.richMessage, .clipboard],
             modelId: uuid(102), imageInputMode: .ocr),
        Role(id: uuid(3), name: "重ねる", icon: "🪟", systemPrompt: "overlay", responsePatterns: [.richMessage, .overlay]),
        Role(id: uuid(4), name: "全部 \"入り\"", icon: "🧑‍💻",
             systemPrompt: "1行目\n2行目\t\"引用\" \\ バックスラッシュ / スラッシュ https://example.com/a?b=c&d=e",
             responsePatterns: [.richMessage, .clipboard, .overlay], modelId: uuid(103)),
    ]

    private static let models: [ModelConfig] = [
        ModelConfig(id: uuid(101), name: "Foundation", provider: .foundationModels, modelIdentifier: "default"),
        ModelConfig(id: uuid(102), name: "Claude", provider: .anthropic, modelIdentifier: "claude-x", thinking: .budget(2048)),
        ModelConfig(id: uuid(103), name: "GPT", provider: .openAI, modelIdentifier: "gpt-x", thinking: .auto),
        ModelConfig(id: uuid(104), name: "Gemini", provider: .gemini, modelIdentifier: "gemini-x", thinking: .off),
        ModelConfig(id: uuid(105), name: "Ollama", provider: .ollama, modelIdentifier: "llama3.2:latest"),
        ModelConfig(id: uuid(106), name: "LM Studio", provider: .lmStudio, modelIdentifier: "qwen/qwen3-8b"),
        ModelConfig(id: uuid(107), name: "OpenRouter", provider: .openResponses, modelIdentifier: "openai/gpt-x"),
    ]

    // MARK: - ロール

    func test_rolesFresh() throws {
        let store = RoleStore(defaults: defaults, addsTranscriptionRole: true)
        XCTAssertFalse(store.roles.isEmpty)
        try snapshot(scenario: "roles-fresh", phase: "after")
    }

    func test_rolesEdit() throws {
        defaults.set(try JSONEncoder().encode(Self.roles), forKey: "roles")
        defaults.set(4, forKey: "rolesSchemaVersion")
        try snapshot(scenario: "roles-edit", phase: "before")

        // shared/src/commonTest の SwiftFixtureReplayTest が同じ順で同じ操作をする。
        let store = RoleStore(defaults: defaults, addsTranscriptionRole: true)
        var first = store.roles[0]
        first.copiesToClipboard = true
        store.update(first)
        var third = store.roles[2]
        third.responsePatterns = [.richMessage]
        third.imageInputMode = .ocr
        store.update(third)
        store.add(Role(id: Self.uuid(5), name: "追加", icon: "➕", systemPrompt: "added", responsePatterns: [.richMessage, .overlay]))
        store.delete(store.roles[1])
        store.move(fromOffsets: IndexSet([0]), toOffset: 3)
        try snapshot(scenario: "roles-edit", phase: "after")
    }

    func test_rolesMigrateFromV0() throws {
        defaults.set(try JSONEncoder().encode(Array(Self.roles.prefix(3))), forKey: "roles")
        try snapshot(scenario: "roles-migrate-v0", phase: "before")
        _ = RoleStore(defaults: defaults, addsTranscriptionRole: true)
        try snapshot(scenario: "roles-migrate-v0", phase: "after")
    }

    func test_rolesMigrateFromV3WithRenamedTranscription() throws {
        var renamed = RoleStore.transcriptionRole
        renamed.name = "書き起こし"
        defaults.set(try JSONEncoder().encode([Self.roles[0], renamed]), forKey: "roles")
        defaults.set(3, forKey: "rolesSchemaVersion")
        try snapshot(scenario: "roles-migrate-v3-renamed", phase: "before")
        _ = RoleStore(defaults: defaults, addsTranscriptionRole: true)
        try snapshot(scenario: "roles-migrate-v3-renamed", phase: "after")
    }

    // MARK: - 設定

    func test_settingsFresh() throws {
        _ = SettingsStore(defaults: defaults, secrets: FixtureSecretStore())
        try snapshot(scenario: "settings-fresh", phase: "after")
    }

    func test_settingsEdit() throws {
        // 既知の要素は Swift のエンコーダに書かせ、別のバージョンが書いた読めない要素だけを足す。
        // 読めない要素は今のどのビルドも書けない形なので、ここだけは手で書くしかない。
        defaults.set(try appending(
            JSONEncoder().encode(Self.models),
            [
                ["id": Self.uuid(108).uuidString, "name": "未来のモデル", "provider": "fromTheFuture", "modelIdentifier": "f-1"],
                ["id": Self.uuid(109).uuidString, "name": "未来の思考", "provider": "anthropic", "modelIdentifier": "c",
                 "thinking": ["effort": ["_0": "high"]]],
            ]
        ), forKey: "models_v2")
        let connections: [BackendProvider: ProviderConnection] = [
            .ollama: ProviderConnection(endpoint: URL(string: "http://192.168.0.20:11434")),
            // Keychain へ移す前の形。読み込みで secrets へ移り、connections から消える。
            .openAI: ProviderConnection(apiKey: "sk-plaintext-legacy"),
            .lmStudio: ProviderConnection(),
        ]
        defaults.set(try appending(
            JSONEncoder().encode(connections),
            ["fromTheFuture", ["endpoint": "https://future.example/"], "gemini", ["endpoint": 42]]
        ), forKey: "connections")
        defaults.set(try JSONEncoder().encode(Optional(Self.uuid(102))), forKey: "defaultModelId")
        try snapshot(scenario: "settings-edit", phase: "before")

        // shared/src/commonTest の SwiftFixtureReplayTest が同じ順で同じ操作をする。
        let secrets = FixtureSecretStore()
        let store = SettingsStore(defaults: defaults, secrets: secrets)
        store.setEndpoint(URL(string: "http://192.168.0.10:1234/v1"), for: .lmStudio)
        store.setEndpoint(URL(string: "https://generativelanguage.googleapis.com/"), for: .gemini)
        store.setAPIKey("sk-or-test", for: .openResponses)
        store.addModel(ModelConfig(id: Self.uuid(110), name: "追加", provider: .openAI, modelIdentifier: "gpt-added", thinking: .budget(500)))
        var first = store.models[0]
        first.thinking = .budget(8192)
        first.name = "Foundation 改"
        store.updateModel(first)
        store.moveModel(fromOffsets: IndexSet([2]), toOffset: 0)
        store.deleteModel(id: Self.uuid(102))
        store.enterToSend = true
        try snapshot(scenario: "settings-edit", phase: "after", secrets: secrets.values)
    }

    func test_settingsNullDefaultModelId() throws {
        defaults.set(try JSONEncoder().encode(Array(Self.models.prefix(2))), forKey: "models_v2")
        defaults.set(try JSONEncoder().encode(UUID?.none), forKey: "defaultModelId")
        try snapshot(scenario: "settings-null-default", phase: "before")
        let store = SettingsStore(defaults: defaults, secrets: FixtureSecretStore())
        XCTAssertEqual(store.defaultModelId, Self.uuid(101))
        try snapshot(scenario: "settings-null-default", phase: "after")
    }

    // MARK: - 書き出し

    /// Swift が書いた JSON 配列の末尾に要素を足す。既知の要素のバイト列は変えない。
    private func appending(_ encoded: Data, _ extra: [Any]) throws -> Data {
        let extraData = try JSONSerialization.data(withJSONObject: extra)
        var data = encoded.dropLast()
        data.append(contentsOf: Array(",".utf8))
        data.append(extraData.dropFirst())
        return Data(data)
    }

    /// suite の中身を 1 キー 1 ファイルで書く。Data は Swift が書いたバイト列のまま残す。
    private func snapshot(scenario: String, phase: String, secrets: [String: String]? = nil) throws {
        let dir = outputDir.appendingPathComponent(scenario).appendingPathComponent(phase)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let domain = defaults.persistentDomain(forName: suite) ?? [:]
        for (key, value) in domain {
            switch value {
            case let data as Data:
                try data.write(to: dir.appendingPathComponent("\(key).data"))
            case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
                try Data((number.boolValue ? "true" : "false").utf8).write(to: dir.appendingPathComponent("\(key).bool"))
            case let number as NSNumber:
                try Data("\(number.intValue)".utf8).write(to: dir.appendingPathComponent("\(key).int"))
            default:
                XCTFail("書き出せない値: \(key) = \(value)")
            }
        }
        if let secrets {
            let data = try JSONSerialization.data(withJSONObject: secrets, options: [.sortedKeys])
            try data.write(to: dir.appendingPathComponent("secrets.json"))
        }
    }
}

private final class FixtureSecretStore: SecretStore {
    var values: [String: String] = [:]
    func get(_ account: String) -> String? { values[account] }
    func set(_ value: String, for account: String) { values[account] = value }
    func delete(_ account: String) { values[account] = nil }
}
