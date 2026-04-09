import Foundation
import Observation

@Observable
final class SettingsStore {
    var connections: [BackendProvider: ProviderConnection] {
        didSet { save() }
    }

    var models: [ModelConfig] {
        didSet { save() }
    }

    var defaultModelId: UUID? {
        didSet { save() }
    }

    // MARK: - Computed

    var defaultModel: ModelConfig? {
        models.first(where: { $0.id == defaultModelId }) ?? models.first
    }

    func model(for id: UUID?) -> ModelConfig? {
        guard let id else { return defaultModel }
        return models.first(where: { $0.id == id }) ?? defaultModel
    }

    func connection(for provider: BackendProvider) -> ProviderConnection {
        connections[provider] ?? ProviderConnection()
    }

    func endpoint(for provider: BackendProvider) -> URL {
        connections[provider]?.endpoint ?? provider.defaultEndpoint
    }

    func apiKey(for provider: BackendProvider) -> String? {
        KeychainService.get("apiKey-\(provider.rawValue)")
    }

    // MARK: - Init

    init() {
        let decoder = JSONDecoder()

        // Load connections
        if let data = UserDefaults.standard.data(forKey: "connections"),
           let decoded = try? decoder.decode([BackendProvider: ProviderConnection].self, from: data) {
            self.connections = decoded
        } else {
            // Migrate from old formats
            var migrated: [BackendProvider: ProviderConnection] = [:]
            if let data = UserDefaults.standard.data(forKey: "apiKeys"),
               let keys = try? decoder.decode([BackendProvider: String].self, from: data) {
                for (provider, key) in keys {
                    migrated[provider] = ProviderConnection(apiKey: key)
                }
            }
            if let data = UserDefaults.standard.data(forKey: "providerConfig"),
               let config = try? decoder.decode(LegacyProviderConfig.self, from: data),
               let endpoint = config.endpoint {
                migrated[config.provider, default: ProviderConnection()].endpoint = endpoint
            }
            if let data = UserDefaults.standard.data(forKey: "backendConfig"),
               let legacy = try? decoder.decode(LegacyBackendConfig.self, from: data) {
                if let key = legacy.apiKey {
                    migrated[legacy.provider, default: ProviderConnection()].apiKey = key
                }
                if let endpoint = legacy.endpoint {
                    migrated[legacy.provider, default: ProviderConnection()].endpoint = endpoint
                }
            }
            self.connections = migrated
        }

        // Load models
        let loadedModels: [ModelConfig]
        if let data = UserDefaults.standard.data(forKey: "models_v2"),
           let decoded = try? decoder.decode([ModelConfig].self, from: data) {
            loadedModels = decoded
        } else {
            loadedModels = ModelConfig.builtinDefaults
        }
        self.models = loadedModels

        // Load default model
        if let data = UserDefaults.standard.data(forKey: "defaultModelId"),
           let decoded = try? decoder.decode(UUID.self, from: data) {
            self.defaultModelId = decoded
        } else {
            self.defaultModelId = loadedModels.first?.id
        }

        // Migrate API keys from UserDefaults connections to Keychain
        migrateAPIKeysToKeychain()
    }

    private func migrateAPIKeysToKeychain() {
        var changed = false
        for (provider, conn) in connections {
            if let key = conn.apiKey, !key.isEmpty {
                KeychainService.set(key, for: "apiKey-\(provider.rawValue)")
                connections[provider]?.apiKey = nil
                changed = true
            }
        }
        if changed { save() }
    }

    // MARK: - Mutations

    func setAPIKey(_ key: String?, for provider: BackendProvider) {
        let account = "apiKey-\(provider.rawValue)"
        if let key, !key.isEmpty {
            KeychainService.set(key, for: account)
        } else {
            KeychainService.delete(account)
        }
    }

    func setEndpoint(_ endpoint: URL?, for provider: BackendProvider) {
        var conn = connections[provider] ?? ProviderConnection()
        conn.endpoint = endpoint
        connections[provider] = conn
    }

    func addModel(_ model: ModelConfig) {
        models.append(model)
        if models.count == 1 {
            defaultModelId = model.id
        }
    }

    func deleteModel(id: UUID) {
        models.removeAll { $0.id == id }
        if defaultModelId == id {
            defaultModelId = models.first?.id
        }
    }

    // MARK: - Persistence

    private func save() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(connections) {
            UserDefaults.standard.set(data, forKey: "connections")
        }
        if let data = try? encoder.encode(models) {
            UserDefaults.standard.set(data, forKey: "models_v2")
        }
        if let data = try? encoder.encode(defaultModelId) {
            UserDefaults.standard.set(data, forKey: "defaultModelId")
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
