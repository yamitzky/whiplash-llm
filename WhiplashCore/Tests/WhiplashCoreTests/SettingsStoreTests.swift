import XCTest
@testable import WhiplashCore

/// 実際の Keychain に触れないための置き場。
private final class InMemorySecretStore: SecretStore {
    var values: [String: String] = [:]
    func get(_ account: String) -> String? { values[account] }
    func set(_ value: String, for account: String) { values[account] = value }
    func delete(_ account: String) { values[account] = nil }
}

@MainActor
final class SettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var secrets: InMemorySecretStore!
    private let suite = "SettingsStoreTests"

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        secrets = InMemorySecretStore()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: defaults, secrets: secrets)
    }

    private func backupKeys(_ key: String) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("\(key).unreadable.") }
    }

    private let mineId = "36557CE8-0000-0000-0000-000000000001"
    private let futureId = "36557CE8-0000-0000-0000-000000000002"

    // MARK: - models_v2

    func test_未知のプロバイダーのモデルがあっても他のモデルは読めて保存しても消えない() throws {
        defaults.set(Data("""
        [{"id":"\(mineId)","name":"自分のモデル","provider":"anthropic","modelIdentifier":"claude-x","thinking":{"off":{}}},
         {"id":"\(futureId)","name":"未来のモデル","provider":"fromTheFuture","modelIdentifier":"f-1"}]
        """.utf8), forKey: "models_v2")

        let store = makeStore()
        XCTAssertEqual(store.models.map(\.name), ["自分のモデル"])

        store.addModel(ModelConfig(name: "追加", provider: .openAI, modelIdentifier: "gpt"))

        let saved = try XCTUnwrap(defaults.data(forKey: "models_v2"))
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [[String: Any]])
        XCTAssertEqual(array.compactMap { $0["name"] as? String }, ["自分のモデル", "追加", "未来のモデル"])
        XCTAssertEqual(array.last?["provider"] as? String, "fromTheFuture")
        XCTAssertEqual(makeStore().models.map(\.name), ["自分のモデル", "追加"])
    }

    func test_未知の思考設定のモデルも読めない要素として残り保存で消えない() throws {
        defaults.set(Data("""
        [{"id":"\(futureId)","name":"未来の思考","provider":"anthropic","modelIdentifier":"c","thinking":{"effort":{"_0":"high"}}}]
        """.utf8), forKey: "models_v2")

        let store = makeStore()
        XCTAssertTrue(store.models.isEmpty)
        store.addModel(ModelConfig(name: "追加", provider: .openAI, modelIdentifier: "gpt"))

        let saved = try XCTUnwrap(String(data: XCTUnwrap(defaults.data(forKey: "models_v2")), encoding: .utf8))
        XCTAssertTrue(saved.contains("\"effort\""))
    }

    func test_読めないモデル一覧は上書きせず原本を残し既定のモデルで始める() {
        let broken = Data("not json".utf8)
        defaults.set(broken, forKey: "models_v2")

        let store = makeStore()
        XCTAssertEqual(store.models.count, ModelConfig.builtinDefaults.count)
        // 関係のない設定を変えても、読めなかったモデル一覧は書き換えない。
        store.setEndpoint(URL(string: "http://localhost:9999"), for: .ollama)
        store.enterToSend = true

        XCTAssertEqual(defaults.data(forKey: "models_v2"), broken)
        let backups = backupKeys("models_v2")
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(defaults.data(forKey: backups[0]), broken)
    }

    func test_読めない原本のバックアップは起動を繰り返しても増えない() {
        defaults.set(Data("not json".utf8), forKey: "models_v2")
        _ = makeStore()
        _ = makeStore()
        XCTAssertEqual(backupKeys("models_v2").count, 1)
    }

    func test_読めない要素がなければ古いビルドと同じ形で保存する() throws {
        let store = makeStore()
        store.addModel(ModelConfig(name: "追加", provider: .openAI, modelIdentifier: "gpt", thinking: .budget(1024)))
        store.setEndpoint(URL(string: "http://localhost:9999"), for: .ollama)

        let models = try JSONDecoder().decode([ModelConfig].self, from: XCTUnwrap(defaults.data(forKey: "models_v2")))
        XCTAssertEqual(models.last?.thinking, .budget(1024))
        let connections = try JSONDecoder().decode([BackendProvider: ProviderConnection].self, from: XCTUnwrap(defaults.data(forKey: "connections")))
        XCTAssertEqual(connections[.ollama]?.endpoint, URL(string: "http://localhost:9999"))
    }

    // MARK: - defaultModelId

    func test_既定モデルが読めない要素として残したモデルを指していても書き換えない() throws {
        defaults.set(Data("""
        [{"id":"\(mineId)","name":"自分のモデル","provider":"anthropic","modelIdentifier":"c"},
         {"id":"\(futureId)","name":"未来のモデル","provider":"fromTheFuture","modelIdentifier":"f"}]
        """.utf8), forKey: "models_v2")
        defaults.set(try JSONEncoder().encode(UUID(uuidString: futureId)), forKey: "defaultModelId")

        let store = makeStore()
        XCTAssertEqual(store.defaultModel?.name, "自分のモデル")
        store.addModel(ModelConfig(name: "追加", provider: .openAI, modelIdentifier: "gpt"))

        let saved = try JSONDecoder().decode(UUID?.self, from: XCTUnwrap(defaults.data(forKey: "defaultModelId")))
        XCTAssertEqual(saved, UUID(uuidString: futureId))
    }

    func test_読めない既定モデルの指定は原本を残す() {
        let broken = Data("not json".utf8)
        defaults.set(broken, forKey: "defaultModelId")
        _ = makeStore()
        XCTAssertEqual(defaults.data(forKey: "defaultModelId"), broken)
        XCTAssertEqual(backupKeys("defaultModelId").count, 1)
    }

    // MARK: - connections

    func test_未知のプロバイダーの接続設定があっても他の接続先は読めて保存しても消えない() throws {
        defaults.set(Data("""
        ["ollama",{"endpoint":"http://mine:11434"},"fromTheFuture",{"endpoint":"https://future.example/"}]
        """.utf8), forKey: "connections")

        let store = makeStore()
        XCTAssertEqual(store.endpoint(for: .ollama), URL(string: "http://mine:11434"))
        store.setEndpoint(URL(string: "http://localhost:1234"), for: .lmStudio)

        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "connections"))) as? [Any])
        let keys = stride(from: 0, to: saved.count, by: 2).compactMap { saved[$0] as? String }
        XCTAssertEqual(Set(keys), ["ollama", "lmStudio", "fromTheFuture"])
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.endpoint(for: .ollama), URL(string: "http://mine:11434"))
        XCTAssertEqual(reloaded.endpoint(for: .lmStudio), URL(string: "http://localhost:1234"))
    }

    func test_読めなかった接続設定は同じプロバイダーを設定し直すと新しい方だけが残る() throws {
        defaults.set(Data(#"["openAI",{"endpoint":123}]"#.utf8), forKey: "connections")

        let store = makeStore()
        store.setEndpoint(URL(string: "https://proxy.example/v1/"), for: .openAI)

        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "connections"))) as? [Any])
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(makeStore().endpoint(for: .openAI), URL(string: "https://proxy.example/v1/"))
    }

    func test_読めない接続設定は旧形式から移行し直さずAPIキーを除いた原本を残す() throws {
        // 鍵と値を交互に並べた配列ではない形。
        let broken = Data(#"{"openAI":{"apiKey":"sk-current","endpoint":"https://proxy.example/v1/"}}"#.utf8)
        defaults.set(broken, forKey: "connections")
        defaults.set(try JSONEncoder().encode([BackendProvider.openAI: "sk-stale"]), forKey: "apiKeys")
        secrets.values["apiKey-openAI"] = "sk-keychain"

        let store = makeStore()

        XCTAssertEqual(store.apiKey(for: .openAI), "sk-keychain")
        XCTAssertEqual(defaults.data(forKey: "connections"), broken)
        let backups = backupKeys("connections")
        XCTAssertEqual(backups.count, 1)
        let backup = try XCTUnwrap(String(data: XCTUnwrap(defaults.data(forKey: backups[0])), encoding: .utf8))
        XCTAssertFalse(backup.contains("sk-current"))
        XCTAssertTrue(backup.contains("proxy.example"))
    }

    func test_旧形式のapiKeysとbackendConfigから接続設定へ移行しAPIキーはKeychainへ移す() throws {
        defaults.set(try JSONEncoder().encode([BackendProvider.anthropic: "sk-ant"]), forKey: "apiKeys")
        defaults.set(Data(#"{"provider":"ollama","endpoint":"http://legacy:11434"}"#.utf8), forKey: "backendConfig")

        let store = makeStore()

        XCTAssertEqual(secrets.values["apiKey-anthropic"], "sk-ant")
        XCTAssertEqual(store.endpoint(for: .ollama), URL(string: "http://legacy:11434"))
        let saved = try XCTUnwrap(String(data: XCTUnwrap(defaults.data(forKey: "connections")), encoding: .utf8))
        XCTAssertFalse(saved.contains("sk-ant"))
    }

    func test_接続設定に平文で残ったAPIキーはKeychainへ移り保存データから消える() throws {
        defaults.set(Data(#"["gemini",{"apiKey":"sk-gem","endpoint":"https://g.example/"}]"#.utf8), forKey: "connections")

        let store = makeStore()

        XCTAssertEqual(secrets.values["apiKey-gemini"], "sk-gem")
        XCTAssertEqual(store.endpoint(for: .gemini), URL(string: "https://g.example/"))
        let saved = try XCTUnwrap(String(data: XCTUnwrap(defaults.data(forKey: "connections")), encoding: .utf8))
        XCTAssertFalse(saved.contains("sk-gem"))
        XCTAssertTrue(backupKeys("connections").isEmpty)
    }

    func test_初回起動の内蔵モデルは保存され次の起動でも同じIDになる() {
        let first = SettingsStore(defaults: defaults, secrets: secrets)
        let second = SettingsStore(defaults: defaults, secrets: secrets)
        XCTAssertFalse(first.models.isEmpty)
        XCTAssertEqual(first.models.map(\.id), second.models.map(\.id))
        XCTAssertEqual(first.defaultModelId, second.defaultModelId)
    }
}
