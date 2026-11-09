import Foundation

/// 設定画面の「一覧から選ぶ」に並べるモデル 1 件。保存はしない（選ぶと modelIdentifier に文字列で入るだけ）。
public struct CatalogModel: Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// "YYYY-MM-DD"。並べ替えにだけ使う。
    public var releaseDate: String?
    /// nil は「分からない」。Ollama / LM Studio の一覧には画像対応の情報がない。
    public var acceptsImages: Bool?

    public init(id: String, name: String, releaseDate: String? = nil, acceptsImages: Bool? = nil) {
        self.id = id
        self.name = name
        self.releaseDate = releaseDate
        self.acceptsImages = acceptsImages
    }
}

/// どこからモデル一覧を取るか。
public enum ModelCatalogSource: Equatable, Sendable {
    /// models.dev の api.json のプロバイダー ID。
    case modelsDev(providerID: String)
    case ollamaTags(URL)
    case openAICompatibleModels(URL)

    public static let modelsDevURL = URL(string: "https://models.dev/api.json")!

    /// Foundation Models は端末内の 1 モデルだけなので一覧を出さない。
    public static func source(for provider: BackendProvider, endpoint: URL) -> ModelCatalogSource? {
        switch provider {
        case .foundationModels: nil
        case .anthropic: .modelsDev(providerID: "anthropic")
        // Open Responses の既定の接続先は OpenRouter だが、models.dev の openrouter は数百件あり
        // ID の形も違う。ここでは OpenAI のモデルを候補に出し、それ以外は自由入力に任せる。
        case .openAI, .openResponses: .modelsDev(providerID: "openai")
        case .gemini: .modelsDev(providerID: "google")
        case .ollama: .ollamaTags(endpoint.appendingPathComponent("api/tags"))
        case .lmStudio: .openAICompatibleModels(openAIModelsURL(endpoint))
        }
    }

    /// LM Studio の接続先は "http://localhost:1234" と "…/v1" のどちらでも書かれうる。
    static func openAIModelsURL(_ endpoint: URL) -> URL {
        let trimmed = endpoint.path.hasSuffix("/") ? String(endpoint.path.dropLast()) : endpoint.path
        if trimmed.hasSuffix("/v1") {
            return endpoint.appendingPathComponent("models")
        }
        return endpoint.appendingPathComponent("v1/models")
    }
}

public enum ModelCatalogError: Error, Equatable {
    case notJSON
    case httpStatus(Int)
}

// MARK: - 解析

public enum ModelCatalogParser {
    /// models.dev の api.json から 1 プロバイダー分を取り出す。
    /// 1 件ずつ JSONSerialization で見るのは、Codable だと 1 件の型違いで全体が読めなくなるため。
    public static func parseModelsDev(_ data: Data, providerID: String) throws -> [CatalogModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelCatalogError.notJSON
        }
        return modelsDevModels(in: root, providerID: providerID)
    }

    /// 全プロバイダー分。キャッシュから読んだときに 1 回で済ませるため。
    public static func parseModelsDevAll(_ data: Data) throws -> [String: [CatalogModel]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelCatalogError.notJSON
        }
        var index: [String: [CatalogModel]] = [:]
        for key in root.keys {
            index[key] = modelsDevModels(in: root, providerID: key)
        }
        return index
    }

    static func modelsDevModels(in root: [String: Any], providerID: String) -> [CatalogModel] {
        guard let provider = root[providerID] as? [String: Any],
              let models = provider["models"] as? [String: Any] else { return [] }

        let parsed: [CatalogModel] = models.compactMap { key, value in
            guard let m = value as? [String: Any] else { return nil }
            let id = (m["id"] as? String) ?? key
            guard !id.isEmpty else { return nil }
            if (m["status"] as? String) == "deprecated" { return nil }
            let modalities = m["modalities"] as? [String: Any]
            let output = modalities?["output"] as? [String] ?? []
            // 出力の情報が無いものも除く。埋め込みや画像生成のモデルを文章生成に選ばせないため。
            guard output.contains("text") else { return nil }
            let input = modalities?["input"] as? [String] ?? []
            let attachment = (m["attachment"] as? Bool) ?? false
            let name = (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return CatalogModel(
                id: id,
                name: name,
                releaseDate: m["release_date"] as? String,
                acceptsImages: attachment || input.contains("image")
            )
        }
        return sortedNewestFirst(parsed)
    }

    /// 公開日の新しい順。日付が無いものは最後、同じ日付は ID 順にして毎回同じ並びにする。
    static func sortedNewestFirst(_ models: [CatalogModel]) -> [CatalogModel] {
        models.sorted { a, b in
            switch (a.releaseDate, b.releaseDate) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.id < b.id
            }
        }
    }

    /// Ollama の GET /api/tags。`{"models":[{"name":"llama3.2:latest","model":"llama3.2:latest",…}]}`
    public static func parseOllamaTags(_ data: Data) throws -> [CatalogModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelCatalogError.notJSON
        }
        let items = root["models"] as? [Any] ?? []
        let models: [CatalogModel] = items.compactMap { item in
            guard let m = item as? [String: Any] else { return nil }
            // 古い Ollama は "model" を返さない。
            guard let id = (m["model"] as? String) ?? (m["name"] as? String), !id.isEmpty else { return nil }
            return CatalogModel(id: id, name: (m["name"] as? String) ?? id)
        }
        return models.sorted { $0.id < $1.id }
    }

    /// OpenAI 互換の GET /v1/models（LM Studio）。`{"data":[{"id":"…","object":"model"}]}`
    public static func parseOpenAIModels(_ data: Data) throws -> [CatalogModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelCatalogError.notJSON
        }
        let items = root["data"] as? [Any] ?? []
        let models: [CatalogModel] = items.compactMap { item in
            guard let m = item as? [String: Any], let id = m["id"] as? String, !id.isEmpty else { return nil }
            // LM Studio は埋め込みモデルも同じ一覧で返す。選んでも文章を生成できないので出さない。
            guard !id.localizedCaseInsensitiveContains("embed") else { return nil }
            return CatalogModel(id: id, name: id)
        }
        return models.sorted { $0.id < $1.id }
    }
}

// MARK: - 取得とキャッシュ

struct ModelsDevDownload: Sendable {
    var index: [String: [CatalogModel]]
    var data: Data
}

/// モデル一覧の取得。外へ送るのは認証情報を付けない GET だけ。
public actor ModelCatalog {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public static let shared = ModelCatalog()
    public static let cacheLifetime: TimeInterval = 24 * 60 * 60

    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private let cacheFile: URL?

    /// 6MB の JSON を開くたびに読み直さないよう、全プロバイダー分を解析済みで持っておく。
    private var modelsDev: [String: [CatalogModel]]?
    private var modelsDevLoadedAt: Date?
    private var inFlight: Task<ModelsDevDownload, Error>?

    public init(
        fetch: @escaping Fetch = ModelCatalog.urlSessionFetch,
        now: @escaping @Sendable () -> Date = { Date() },
        cacheFile: URL? = ModelCatalog.defaultCacheFile
    ) {
        self.fetch = fetch
        self.now = now
        self.cacheFile = cacheFile
    }

    public func models(for provider: BackendProvider, endpoint: URL) async throws -> [CatalogModel] {
        guard let source = ModelCatalogSource.source(for: provider, endpoint: endpoint) else { return [] }
        switch source {
        case .modelsDev(let providerID):
            return try await loadModelsDev()[providerID] ?? []
        // 手元のサーバーは入れたり消したりがすぐ反映されてほしいのでキャッシュしない。
        case .ollamaTags(let url):
            return try ModelCatalogParser.parseOllamaTags(await fetch(url))
        case .openAICompatibleModels(let url):
            return try ModelCatalogParser.parseOpenAIModels(await fetch(url))
        }
    }

    private func loadModelsDev() async throws -> [String: [CatalogModel]] {
        if let modelsDev, let loadedAt = modelsDevLoadedAt, isFresh(loadedAt) {
            return modelsDev
        }
        let cached = readCache()
        if let cached, isFresh(cached.date) {
            modelsDev = cached.index
            modelsDevLoadedAt = cached.date
            return cached.index
        }
        // 設定画面で複数の欄が同時に開いても取りに行くのは 1 回にする。
        let task: Task<ModelsDevDownload, Error>
        let isFirst = inFlight == nil
        if let inFlight {
            task = inFlight
        } else {
            task = Task { [fetch] in
                let data = try await fetch(ModelCatalogSource.modelsDevURL)
                return ModelsDevDownload(index: try ModelCatalogParser.parseModelsDevAll(data), data: data)
            }
            inFlight = task
        }
        do {
            let result = try await task.value
            if isFirst {
                inFlight = nil
                writeCache(result.data)
                modelsDev = result.index
                modelsDevLoadedAt = now()
            }
            return result.index
        } catch {
            if isFirst { inFlight = nil }
            // 取れなかったときは古くても手元のものを出す。一覧は補助なので空よりはよい。
            // 取得時刻は古いままにして、次に開いたときにまた取りに行く。
            if let modelsDev { return modelsDev }
            if let cached {
                modelsDev = cached.index
                modelsDevLoadedAt = cached.date
                return cached.index
            }
            throw error
        }
    }

    private func isFresh(_ date: Date) -> Bool {
        now().timeIntervalSince(date) < Self.cacheLifetime
    }

    private func readCache() -> (index: [String: [CatalogModel]], date: Date)? {
        guard let cacheFile,
              let data = try? Data(contentsOf: cacheFile),
              let index = try? ModelCatalogParser.parseModelsDevAll(data),
              let attributes = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
              let date = attributes[.modificationDate] as? Date else { return nil }
        return (index, date)
    }

    private func writeCache(_ data: Data) {
        guard let cacheFile else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: cacheFile, options: .atomic)) != nil else { return }
        // 有効期限は注入した時計で測るので、更新日時もその時計に合わせる。
        try? fm.setAttributes([.modificationDate: now()], ofItemAtPath: cacheFile.path)
    }

    public static var defaultCacheFile: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = Bundle.main.bundleIdentifier ?? "WhiplashCore"
        return caches.appendingPathComponent(folder).appendingPathComponent("models.dev-api.json")
    }

    public static let urlSessionFetch: Fetch = { url in
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        // 認証情報や Cookie を付けない。
        request.httpShouldHandleCookies = false
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelCatalogError.httpStatus(http.statusCode)
        }
        return data
    }
}

extension CatalogModel {
    /// 一覧から選んだときの表示名。ユーザーが自分で付けた名前は上書きしない。
    /// 空、前のモデル ID のまま（追加時に名前を省くと ID が入る）、組み込みの既定名のときだけ一覧の名前にする。
    public static func displayName(afterPicking picked: CatalogModel, currentName: String, previousIdentifier: String) -> String {
        let trimmed = currentName.trimmingCharacters(in: .whitespaces)
        let isDefault = trimmed.isEmpty
            || trimmed == previousIdentifier
            || ModelConfig.builtinDefaults.contains { $0.name == trimmed }
        return isDefault ? picked.name : currentName
    }
}
