import XCTest
@testable import WhiplashCore

/// models.dev の api.json から必要な形だけ切り出したもの。実物は約 6MB あるので入れない。
private let modelsDevFixture = Data("""
{
  "anthropic": {
    "id": "anthropic", "name": "Anthropic",
    "models": {
      "claude-sonnet-4-5-20250929": {
        "id": "claude-sonnet-4-5-20250929", "name": "Claude Sonnet 4.5", "attachment": true, "reasoning": true,
        "release_date": "2025-09-29", "modalities": {"input": ["text", "image", "pdf"], "output": ["text"]}
      },
      "claude-haiku-4-5-20251001": {
        "id": "claude-haiku-4-5-20251001", "name": "Claude Haiku 4.5", "attachment": false,
        "release_date": "2025-10-01", "modalities": {"input": ["text", "image"], "output": ["text"]}
      },
      "claude-old": {
        "id": "claude-old", "name": "Claude Old", "status": "deprecated",
        "release_date": "2026-01-01", "modalities": {"input": ["text"], "output": ["text"]}
      },
      "broken": "これはモデルではない",
      "claude-text-only": {
        "id": "claude-text-only", "name": "Claude Text", "attachment": false,
        "release_date": "2024-01-01", "modalities": {"input": ["text"], "output": ["text"]}
      }
    }
  },
  "openai": {
    "models": {
      "gpt-image": {
        "id": "gpt-image", "name": "GPT Image", "release_date": "2026-02-01",
        "modalities": {"input": ["text"], "output": ["image"]}
      },
      "text-embedding": {
        "id": "text-embedding", "name": "Embedding", "release_date": "2026-03-01",
        "modalities": {"input": ["text"], "output": ["embedding"]}
      },
      "gpt-b": {"id": "gpt-b", "name": "GPT B", "release_date": "2025-05-05", "modalities": {"input": ["text"], "output": ["text"]}},
      "gpt-a": {"id": "gpt-a", "name": "GPT A", "release_date": "2025-05-05", "modalities": {"input": ["text"], "output": ["text"]}},
      "gpt-nodate": {"id": "gpt-nodate", "name": "", "modalities": {"input": ["text"], "output": ["text"]}},
      "gpt-badname": {"id": "gpt-badname", "name": 42, "release_date": 20250101, "modalities": {"input": ["text"], "output": ["text"]}}
    }
  },
  "google": {
    "models": {
      "gemini-2.5-flash": {
        "id": "gemini-2.5-flash", "name": "Gemini 2.5 Flash", "attachment": true,
        "release_date": "2025-06-17", "modalities": {"input": ["text", "image"], "output": ["text"]}
      }
    }
  }
}
""".utf8)

/// 呼ばれた URL を記録し、決めた応答を返す通信の代わり。
private final class FakeFetcher: @unchecked Sendable {
    private let lock = NSLock()
    private var _requested: [URL] = []
    var response: Result<Data, Error>

    init(_ response: Result<Data, Error>) { self.response = response }

    var requested: [URL] { lock.withLock { _requested } }

    func fetch(_ url: URL) async throws -> Data {
        let r: Result<Data, Error> = lock.withLock {
            _requested.append(url)
            return response
        }
        return try r.get()
    }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
}

private struct Offline: Error {}

final class ModelCatalogTests: XCTestCase {
    private var cacheDir: URL!

    override func setUp() {
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelCatalogTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDir)
    }

    private var cacheFile: URL { cacheDir.appendingPathComponent("models.dev-api.json") }

    private func makeCatalog(_ fetcher: FakeFetcher, _ clock: FakeClock) -> ModelCatalog {
        ModelCatalog(fetch: { try await fetcher.fetch($0) }, now: { clock.now }, cacheFile: cacheFile)
    }

    // MARK: - 解析

    func test_modelsdevの1プロバイダー分を名前と公開日と画像対応つきで読む() throws {
        let models = try ModelCatalogParser.parseModelsDev(modelsDevFixture, providerID: "anthropic")
        let sonnet = try XCTUnwrap(models.first { $0.id == "claude-sonnet-4-5-20250929" })
        XCTAssertEqual(sonnet.name, "Claude Sonnet 4.5")
        XCTAssertEqual(sonnet.releaseDate, "2025-09-29")
        XCTAssertEqual(sonnet.acceptsImages, true)
    }

    func test_attachmentが偽でも入力にimageがあれば画像対応とみなす() throws {
        let models = try ModelCatalogParser.parseModelsDev(modelsDevFixture, providerID: "anthropic")
        XCTAssertEqual(models.first { $0.id == "claude-haiku-4-5-20251001" }?.acceptsImages, true)
        XCTAssertEqual(models.first { $0.id == "claude-text-only" }?.acceptsImages, false)
    }

    func test_モデルでない要素や型の違う項目があっても他のモデルは読める() throws {
        let anthropic = try ModelCatalogParser.parseModelsDev(modelsDevFixture, providerID: "anthropic")
        XCTAssertEqual(anthropic.count, 3)

        let openai = try ModelCatalogParser.parseModelsDev(modelsDevFixture, providerID: "openai")
        let bad = try XCTUnwrap(openai.first { $0.id == "gpt-badname" })
        XCTAssertEqual(bad.name, "gpt-badname", "名前が文字列でなければ ID を名前にする")
        XCTAssertNil(bad.releaseDate)
        XCTAssertEqual(openai.first { $0.id == "gpt-nodate" }?.name, "gpt-nodate", "空の名前も ID で埋める")
    }

    func test_JSONでなければ失敗を返し無いプロバイダーは空にする() throws {
        XCTAssertThrowsError(try ModelCatalogParser.parseModelsDev(Data("<html>".utf8), providerID: "anthropic"))
        XCTAssertEqual(try ModelCatalogParser.parseModelsDev(modelsDevFixture, providerID: "nope"), [])
    }

    // MARK: - 除外と並び順

    func test_廃止済みと文章を出力しないモデルを除く() throws {
        let anthropic = try ModelCatalogParser.parseModelsDev(modelsDevFixture, providerID: "anthropic")
        XCTAssertFalse(anthropic.contains { $0.id == "claude-old" })

        let openai = try ModelCatalogParser.parseModelsDev(modelsDevFixture, providerID: "openai")
        XCTAssertFalse(openai.contains { $0.id == "gpt-image" })
        XCTAssertFalse(openai.contains { $0.id == "text-embedding" })
    }

    func test_公開日の新しい順で同じ日はID順で日付なしは最後() throws {
        let anthropic = try ModelCatalogParser.parseModelsDev(modelsDevFixture, providerID: "anthropic")
        XCTAssertEqual(anthropic.map(\.id), ["claude-haiku-4-5-20251001", "claude-sonnet-4-5-20250929", "claude-text-only"])

        let openai = try ModelCatalogParser.parseModelsDev(modelsDevFixture, providerID: "openai")
        XCTAssertEqual(openai.map(\.id), ["gpt-a", "gpt-b", "gpt-badname", "gpt-nodate"])
    }

    // MARK: - プロバイダー対応

    func test_各プロバイダーの一覧の取り先() {
        let any = URL(string: "http://example.invalid")!
        XCTAssertEqual(ModelCatalogSource.source(for: .anthropic, endpoint: any), .modelsDev(providerID: "anthropic"))
        XCTAssertEqual(ModelCatalogSource.source(for: .openAI, endpoint: any), .modelsDev(providerID: "openai"))
        XCTAssertEqual(ModelCatalogSource.source(for: .openResponses, endpoint: any), .modelsDev(providerID: "openai"))
        XCTAssertEqual(ModelCatalogSource.source(for: .gemini, endpoint: any), .modelsDev(providerID: "google"))
        XCTAssertNil(ModelCatalogSource.source(for: .foundationModels, endpoint: any))
    }

    func test_OllamaとLMStudioは接続先から一覧のURLを作る() {
        XCTAssertEqual(
            ModelCatalogSource.source(for: .ollama, endpoint: URL(string: "http://localhost:11434")!),
            .ollamaTags(URL(string: "http://localhost:11434/api/tags")!))
        XCTAssertEqual(
            ModelCatalogSource.source(for: .lmStudio, endpoint: URL(string: "http://localhost:1234")!),
            .openAICompatibleModels(URL(string: "http://localhost:1234/v1/models")!))
        XCTAssertEqual(
            ModelCatalogSource.source(for: .lmStudio, endpoint: URL(string: "http://192.168.0.2:1234/v1/")!),
            .openAICompatibleModels(URL(string: "http://192.168.0.2:1234/v1/models")!))
    }

    func test_接続先に応じてGeminiはgoogleの一覧を返しFoundationModelsは取りに行かない() async throws {
        let fetcher = FakeFetcher(.success(modelsDevFixture))
        let catalog = makeCatalog(fetcher, FakeClock())

        let gemini = try await catalog.models(for: .gemini, endpoint: BackendProvider.gemini.defaultEndpoint)
        XCTAssertEqual(gemini.map(\.id), ["gemini-2.5-flash"])
        let fm = try await catalog.models(for: .foundationModels, endpoint: BackendProvider.foundationModels.defaultEndpoint)
        XCTAssertEqual(fm, [])
        XCTAssertEqual(fetcher.requested, [ModelCatalogSource.modelsDevURL])
    }

    // MARK: - キャッシュ

    func test_24時間以内はキャッシュを使い過ぎたら取り直す() async throws {
        let fetcher = FakeFetcher(.success(modelsDevFixture))
        let clock = FakeClock()

        _ = try await makeCatalog(fetcher, clock).models(for: .anthropic, endpoint: BackendProvider.anthropic.defaultEndpoint)
        XCTAssertEqual(fetcher.requested.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))

        // アプリを起動し直してもファイルのキャッシュを使う。
        clock.now += 23 * 60 * 60
        let again = try await makeCatalog(fetcher, clock).models(for: .anthropic, endpoint: BackendProvider.anthropic.defaultEndpoint)
        XCTAssertEqual(fetcher.requested.count, 1)
        XCTAssertEqual(again.count, 3)

        clock.now += 2 * 60 * 60
        _ = try await makeCatalog(fetcher, clock).models(for: .anthropic, endpoint: BackendProvider.anthropic.defaultEndpoint)
        XCTAssertEqual(fetcher.requested.count, 2)
    }

    func test_取得に失敗したら期限切れのキャッシュでも使う() async throws {
        let fetcher = FakeFetcher(.success(modelsDevFixture))
        let clock = FakeClock()
        _ = try await makeCatalog(fetcher, clock).models(for: .anthropic, endpoint: BackendProvider.anthropic.defaultEndpoint)

        clock.now += 30 * 24 * 60 * 60
        fetcher.response = .failure(Offline())
        let catalog = makeCatalog(fetcher, clock)
        let stale = try await catalog.models(for: .anthropic, endpoint: BackendProvider.anthropic.defaultEndpoint)
        XCTAssertEqual(stale.count, 3)
        XCTAssertEqual(fetcher.requested.count, 2)

        // 次に開いたときはまた取りに行き、取れたら新しいものにする。
        fetcher.response = .success(Data(#"{"anthropic":{"models":{}}}"#.utf8))
        let fresh = try await catalog.models(for: .anthropic, endpoint: BackendProvider.anthropic.defaultEndpoint)
        XCTAssertEqual(fresh, [])
        XCTAssertEqual(fetcher.requested.count, 3)
    }

    func test_キャッシュが無く取得にも失敗したらエラーを返す() async {
        let fetcher = FakeFetcher(.failure(Offline()))
        let catalog = makeCatalog(fetcher, FakeClock())
        do {
            _ = try await catalog.models(for: .openAI, endpoint: BackendProvider.openAI.defaultEndpoint)
            XCTFail("エラーになるはず")
        } catch {
            XCTAssertTrue(error is Offline)
        }
    }

    func test_JSONでない応答はキャッシュに書かない() async throws {
        let fetcher = FakeFetcher(.success(Data("<html>メンテナンス中</html>".utf8)))
        let catalog = makeCatalog(fetcher, FakeClock())
        do {
            _ = try await catalog.models(for: .anthropic, endpoint: BackendProvider.anthropic.defaultEndpoint)
            XCTFail("エラーになるはず")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    func test_OllamaとLMStudioは毎回接続先に取りに行きキャッシュしない() async throws {
        let fetcher = FakeFetcher(.success(Data(#"{"models":[{"name":"llama3.2:latest","model":"llama3.2:latest"}]}"#.utf8)))
        let catalog = makeCatalog(fetcher, FakeClock())
        let endpoint = URL(string: "http://localhost:11434")!
        _ = try await catalog.models(for: .ollama, endpoint: endpoint)
        _ = try await catalog.models(for: .ollama, endpoint: endpoint)
        XCTAssertEqual(fetcher.requested, [URL(string: "http://localhost:11434/api/tags")!, URL(string: "http://localhost:11434/api/tags")!])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    // MARK: - Ollama / LM Studio の応答

    func test_Ollamaのapi_tagsを読み名前順に並べる() throws {
        let data = Data("""
        {"models":[
          {"name":"qwen3:8b","model":"qwen3:8b","modified_at":"2025-05-01T00:00:00Z","size":1,"details":{"family":"qwen3"}},
          {"name":"llama3.2:latest","model":"llama3.2:latest"},
          {"name":"old-ollama"},
          {"size":3},
          "壊れた要素"
        ]}
        """.utf8)
        let models = try ModelCatalogParser.parseOllamaTags(data)
        XCTAssertEqual(models.map(\.id), ["llama3.2:latest", "old-ollama", "qwen3:8b"])
        XCTAssertNil(models.first?.acceptsImages, "tags には画像対応の情報が無い")
    }

    func test_LMStudioのv1_modelsを読む() throws {
        let data = Data("""
        {"object":"list","data":[
          {"id":"qwen2.5-7b-instruct","object":"model","owned_by":"organization_owner"},
          {"id":"google/gemma-3-12b","object":"model"},
          {"object":"model"}
        ]}
        """.utf8)
        XCTAssertEqual(try ModelCatalogParser.parseOpenAIModels(data).map(\.id), ["google/gemma-3-12b", "qwen2.5-7b-instruct"])
        XCTAssertThrowsError(try ModelCatalogParser.parseOpenAIModels(Data("not json".utf8)))
    }

    // MARK: - 選んだときの表示名

    func test_表示名が空か前のIDか既定名のときだけ一覧の名前にする() {
        let picked = CatalogModel(id: "claude-sonnet-4-5-20250929", name: "Claude Sonnet 4.5")
        XCTAssertEqual(CatalogModel.displayName(afterPicking: picked, currentName: "", previousIdentifier: ""), "Claude Sonnet 4.5")
        XCTAssertEqual(CatalogModel.displayName(afterPicking: picked, currentName: "claude-x", previousIdentifier: "claude-x"), "Claude Sonnet 4.5")
        XCTAssertEqual(CatalogModel.displayName(afterPicking: picked, currentName: "Claude Sonnet", previousIdentifier: "claude-x"), "Claude Sonnet 4.5")
        XCTAssertEqual(CatalogModel.displayName(afterPicking: picked, currentName: "仕事用", previousIdentifier: "claude-x"), "仕事用")
    }

    func test_LMStudioの一覧から埋め込みモデルを除く() throws {
        let data = Data(#"{"data":[{"id":"plamo-2-translate"},{"id":"text-embedding-nomic-embed-text-v1.5"}]}"#.utf8)
        XCTAssertEqual(try ModelCatalogParser.parseOpenAIModels(data).map(\.id), ["plamo-2-translate"])
    }
}
