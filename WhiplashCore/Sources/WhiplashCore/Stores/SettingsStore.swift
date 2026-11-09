import Foundation
import Observation

@Observable
@MainActor
public final class SettingsStore {
    public var connections: [BackendProvider: ProviderConnection] {
        didSet { saveConnections() }
    }

    public var models: [ModelConfig] {
        didSet { saveModels() }
    }

    public var defaultModelId: UUID? {
        // Optional なので init の途中で self の初期化が済み、init 内の代入でも didSet が走る。
        // 読み込みの代入で、読めなかった原本を上書きしないよう読み込み中は書かない。
        didSet { if !isLoading { saveDefaultModelId() } }
    }

    /// true = Enter sends, Shift+Enter for newline. false (default) = Ctrl+Enter sends, Enter for newline.
    public var enterToSend: Bool {
        didSet { defaults.set(enterToSend, forKey: "enterToSend") }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: SecretStore
    /// 別のバージョンが書いた、このビルドでは読めない要素。保存のたびに書き戻して消さない。
    @ObservationIgnored private var unreadableConnections: [(key: Data, value: Data)] = []
    @ObservationIgnored private var unreadableModels: [Data] = []
    @ObservationIgnored private var isLoading = true

    // MARK: - Computed

    public var defaultModel: ModelConfig? {
        models.first(where: { $0.id == defaultModelId }) ?? models.first
    }

    public func model(for id: UUID?) -> ModelConfig? {
        guard let id else { return defaultModel }
        return models.first(where: { $0.id == id }) ?? defaultModel
    }

    public func connection(for provider: BackendProvider) -> ProviderConnection {
        connections[provider] ?? ProviderConnection()
    }

    public func endpoint(for provider: BackendProvider) -> URL {
        connections[provider]?.endpoint ?? provider.defaultEndpoint
    }

    public func apiKey(for provider: BackendProvider) -> String? {
        secrets.get("apiKey-\(provider.rawValue)")
    }

    // MARK: - Init

    public init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
        self.enterToSend = defaults.bool(forKey: "enterToSend")

        // Load connections
        if let data = defaults.data(forKey: "connections") {
            if let loaded = PreservingConnections(data: data) {
                self.connections = loaded.connections
                self.unreadableConnections = loaded.unreadable
            } else {
                // 旧形式からの移行に進むと、古い apiKeys の値で今の Keychain の API キーを上書きしてしまう。
                let backupKey = defaults.backUpUnreadable(Self.withoutAPIKeys(data), forKey: "connections")
                print("[SettingsStore] Could not decode connections, kept a copy at \(backupKey)")
                self.connections = [:]
            }
        } else {
            self.connections = Self.migrateLegacyConnections(defaults)
        }

        // Load models
        let loadedModels: [ModelConfig]
        if let data = defaults.data(forKey: "models_v2") {
            if let loaded = PreservingArray<ModelConfig>(data: data) {
                loadedModels = loaded.elements
                self.unreadableModels = loaded.unreadable
            } else {
                let backupKey = defaults.backUpUnreadable(data, forKey: "models_v2")
                print("[SettingsStore] Could not decode models, kept a copy at \(backupKey)")
                loadedModels = ModelConfig.builtinDefaults
            }
        } else {
            loadedModels = ModelConfig.builtinDefaults
        }
        let modelsWereMissing = defaults.data(forKey: "models_v2") == nil
        let defaultModelIdWasMissing = defaults.data(forKey: "defaultModelId") == nil
        self.models = loadedModels

        // Load default model
        if let data = defaults.data(forKey: "defaultModelId") {
            if let decoded = try? JSONDecoder().decode(UUID?.self, from: data) {
                // 読めない要素として残したモデルを指していても書き換えない。defaultModel が先頭へ代替する。
                self.defaultModelId = decoded ?? loadedModels.first?.id
            } else {
                let backupKey = defaults.backUpUnreadable(data, forKey: "defaultModelId")
                print("[SettingsStore] Could not decode defaultModelId, kept a copy at \(backupKey)")
                self.defaultModelId = loadedModels.first?.id
            }
        } else {
            self.defaultModelId = loadedModels.first?.id
        }

        isLoading = false

        // builtinDefaults の UUID は起動ごとに作り直されるので、保存しないとロールが選んだモデルを次の起動で見失う。
        // 既にある値は、読めなかった原本も含めて書き換えない。
        if modelsWereMissing { saveModels() }
        if modelsWereMissing && defaultModelIdWasMissing { saveDefaultModelId() }

        // Migrate API keys from UserDefaults connections to Keychain
        migrateAPIKeysToKeychain()
    }

    private static func migrateLegacyConnections(_ defaults: UserDefaults) -> [BackendProvider: ProviderConnection] {
        let decoder = JSONDecoder()
        var migrated: [BackendProvider: ProviderConnection] = [:]
        if let data = defaults.data(forKey: "apiKeys"),
           let keys = try? decoder.decode([BackendProvider: String].self, from: data) {
            for (provider, key) in keys {
                migrated[provider] = ProviderConnection(apiKey: key)
            }
        }
        if let data = defaults.data(forKey: "providerConfig"),
           let config = try? decoder.decode(LegacyProviderConfig.self, from: data),
           let endpoint = config.endpoint {
            migrated[config.provider, default: ProviderConnection()].endpoint = endpoint
        }
        if let data = defaults.data(forKey: "backendConfig"),
           let legacy = try? decoder.decode(LegacyBackendConfig.self, from: data) {
            if let key = legacy.apiKey {
                migrated[legacy.provider, default: ProviderConnection()].apiKey = key
            }
            if let endpoint = legacy.endpoint {
                migrated[legacy.provider, default: ProviderConnection()].endpoint = endpoint
            }
        }
        return migrated
    }

    /// Keychain 移行前の connections には API キーが平文で入っている。原本は移行で消えるので、
    /// バックアップにだけ平文の API キーが残り続けないよう取り除く。
    /// JSON として読めないものは取り除きようがないので、そのまま残す(消すと戻せない)。
    private static func withoutAPIKeys(_ data: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return data }
        func strip(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                return dict.filter { $0.key != "apiKey" }.mapValues(strip)
            }
            if let array = value as? [Any] {
                return array.map(strip)
            }
            return value
        }
        return (try? JSONSerialization.data(withJSONObject: strip(object), options: [.fragmentsAllowed])) ?? data
    }

    private func migrateAPIKeysToKeychain() {
        for (provider, conn) in connections {
            if let key = conn.apiKey, !key.isEmpty {
                secrets.set(key, for: "apiKey-\(provider.rawValue)")
                connections[provider]?.apiKey = nil
            }
        }
    }

    // MARK: - Mutations

    public func setAPIKey(_ key: String?, for provider: BackendProvider) {
        let account = "apiKey-\(provider.rawValue)"
        if let key, !key.isEmpty {
            secrets.set(key, for: account)
        } else {
            secrets.delete(account)
        }
    }

    public func setEndpoint(_ endpoint: URL?, for provider: BackendProvider) {
        var conn = connections[provider] ?? ProviderConnection()
        conn.endpoint = endpoint
        connections[provider] = conn
    }

    public func addModel(_ model: ModelConfig) {
        models.append(model)
        if models.count == 1 {
            defaultModelId = model.id
        }
    }

    public func updateModel(_ model: ModelConfig) {
        guard let index = models.firstIndex(where: { $0.id == model.id }) else { return }
        models[index] = model
    }

    public func moveModel(fromOffsets source: IndexSet, toOffset destination: Int) {
        models.move(fromOffsets: source, toOffset: destination)
    }

    public func deleteModel(id: UUID) {
        models.removeAll { $0.id == id }
        if defaultModelId == id {
            defaultModelId = models.first?.id
        }
    }

    // MARK: - Persistence

    // 変えたキーだけを書く。読めなかった別のキーを、関係のない変更のついでに上書きしないため。
    private func saveConnections() {
        if let data = try? PreservingConnections.encode(connections, preserving: unreadableConnections) {
            defaults.set(data, forKey: "connections")
        }
    }

    private func saveModels() {
        if let data = try? PreservingArray.encode(models, preserving: unreadableModels) {
            defaults.set(data, forKey: "models_v2")
        }
    }

    private func saveDefaultModelId() {
        if let data = try? JSONEncoder().encode(defaultModelId) {
            defaults.set(data, forKey: "defaultModelId")
        }
    }
}

// MARK: - Legacy migration types

private struct LegacyBackendConfig: Codable {
    var provider: BackendProvider
    var modelName: String?
    var endpoint: URL?
    var apiKey: String?
}

private struct LegacyProviderConfig: Codable {
    var provider: BackendProvider
    var endpoint: URL?
}
