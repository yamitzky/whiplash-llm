import XCTest
@testable import WhiplashCore

@MainActor
final class RoleStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "RoleStoreTests"

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func roleJSON(patterns: String) -> Data {
        Data("""
        [{"id":"36557CE8-0000-0000-0000-000000000001","name":"人間語","icon":"🗣","systemPrompt":"自分のプロンプト","responsePatterns":\(patterns)}]
        """.utf8)
    }

    func test_未知の応答パターンがあってもロールは失われず未知の値だけ除かれる() {
        defaults.set(roleJSON(patterns: #"["richMessage","fromTheFuture"]"#), forKey: "roles")
        let store = RoleStore(defaults: defaults, addsTranscriptionRole: false)
        XCTAssertEqual(store.roles.map(\.name), ["人間語"])
        XCTAssertEqual(store.roles[0].responsePatterns, [.richMessage])
    }

    func test_読めないデータは上書きせず原本を残す() {
        let broken = Data("not json".utf8)
        defaults.set(broken, forKey: "roles")
        _ = RoleStore(defaults: defaults)
        XCTAssertEqual(defaults.data(forKey: "roles"), broken)
        let backups = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("roles.unreadable.") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(defaults.data(forKey: backups[0]), broken)
    }

    func test_保存データがなければプリセットで始める() {
        let store = RoleStore(defaults: defaults, addsTranscriptionRole: false)
        XCTAssertEqual(store.roles.count, RoleStore.presets.count)
        XCTAssertNotNil(defaults.data(forKey: "roles"))
    }

    /// 4 月時点の Role と同じく、responsePatterns の未知の値で失敗する読み込み。
    private struct LegacyRole: Decodable {
        enum Pattern: String, Decodable { case richMessage, clipboard }
        let id: UUID
        let name: String
        let icon: String
        let systemPrompt: String
        let responsePatterns: [Pattern]
    }

    func test_オーバーレイを選んだロールも古いビルドの読み込みで失敗しない() throws {
        let store = RoleStore(defaults: defaults)
        var role = store.roles[0]
        role.responsePatterns = [.richMessage, .overlay]
        store.update(role)

        let data = try XCTUnwrap(defaults.data(forKey: "roles"))
        let legacy = try JSONDecoder().decode([LegacyRole].self, from: data)
        XCTAssertEqual(legacy[0].responsePatterns, [.richMessage])
    }

    func test_オーバーレイの設定は保存と読み込みで失われない() {
        let store = RoleStore(defaults: defaults)
        var role = store.roles[0]
        role.responsePatterns = [.richMessage, .overlay]
        store.update(role)

        XCTAssertEqual(RoleStore(defaults: defaults).roles[0].responsePatterns, [.richMessage, .overlay])
    }

    func test_旧形式のoverlayは新形式へ移行し原本を残す() throws {
        let original = roleJSON(patterns: #"["richMessage","overlay"]"#)
        defaults.set(original, forKey: "roles")

        let store = RoleStore(defaults: defaults)

        XCTAssertEqual(store.roles[0].responsePatterns, [.richMessage, .overlay])
        XCTAssertEqual(store.roles[0].systemPrompt, "自分のプロンプト")
        XCTAssertEqual(defaults.data(forKey: "roles.backup.v0"), original)
        let migrated = try XCTUnwrap(defaults.data(forKey: "roles"))
        XCTAssertNoThrow(try JSONDecoder().decode([LegacyRole].self, from: migrated))
    }

    func test_移行は一度だけで原本のバックアップを上書きしない() {
        let original = roleJSON(patterns: #"["richMessage"]"#)
        defaults.set(original, forKey: "roles")
        let store = RoleStore(defaults: defaults)
        var role = store.roles[0]
        role.name = "変更後"
        store.update(role)

        _ = RoleStore(defaults: defaults)

        XCTAssertEqual(defaults.data(forKey: "roles.backup.v0"), original)
        XCTAssertEqual(RoleStore(defaults: defaults).roles[0].name, "変更後")
    }

    func test_未知の画像入力方式があってもロールは失われない() {
        defaults.set(Data("""
        [{"id":"36557CE8-0000-0000-0000-000000000001","name":"人間語","icon":"🗣","systemPrompt":"p","responsePatterns":["richMessage"],"imageInputMode":"fromTheFuture"}]
        """.utf8), forKey: "roles")
        let store = RoleStore(defaults: defaults, addsTranscriptionRole: false)
        XCTAssertEqual(store.roles.map(\.name), ["人間語"])
        XCTAssertEqual(store.roles[0].imageInputMode, .image)
    }

    func test_自動コピーを切り替えても古いビルドでボックスが出る形で保存される() throws {
        let store = RoleStore(defaults: defaults)
        var role = store.roles[0]
        role.copiesToClipboard = true
        store.update(role)
        XCTAssertTrue(RoleStore(defaults: defaults).roles[0].copiesToClipboard)

        let legacy = try JSONDecoder().decode([LegacyRole].self, from: XCTUnwrap(defaults.data(forKey: "roles")))
        XCTAssertEqual(legacy[0].responsePatterns, [.richMessage, .clipboard])

        role.copiesToClipboard = false
        store.update(role)
        let legacyOff = try JSONDecoder().decode([LegacyRole].self, from: XCTUnwrap(defaults.data(forKey: "roles")))
        XCTAssertEqual(legacyOff[0].responsePatterns, [.richMessage])
    }

    func test_新規インストールには文字起こしロールが入る() {
        let store = RoleStore(defaults: defaults, addsTranscriptionRole: true)
        XCTAssertEqual(store.roles.last?.name, "文字起こし")
        XCTAssertEqual(store.roles.count, RoleStore.presets.count + 1)
    }

    func test_文字起こしロールを足さない設定なら新規インストールに入れない() {
        let store = RoleStore(defaults: defaults, addsTranscriptionRole: false)
        XCTAssertFalse(store.roles.contains { $0.name == "文字起こし" })
    }

    func test_v3まで移行済みのmacOSにも文字起こしロールを一度だけ足す() {
        defaults.set(roleJSON(patterns: #"["richMessage"]"#), forKey: "roles")
        defaults.set(3, forKey: "rolesSchemaVersion")

        XCTAssertEqual(RoleStore(defaults: defaults).roles.map(\.name), ["人間語", "文字起こし"])
        XCTAssertNotNil(defaults.data(forKey: "roles.backup.v3"))
    }

    func test_既存ユーザーには移行で文字起こしロールを一度だけ足し自分のロールは残す() {
        defaults.set(roleJSON(patterns: #"["richMessage"]"#), forKey: "roles")
        defaults.set(2, forKey: "rolesSchemaVersion")

        let store = RoleStore(defaults: defaults, addsTranscriptionRole: true)
        XCTAssertEqual(store.roles.map(\.name), ["人間語", "文字起こし"])

        // 利用者が消したら、次の起動で足し直さない。
        store.delete(store.roles[1])
        XCTAssertEqual(RoleStore(defaults: defaults, addsTranscriptionRole: true).roles.map(\.name), ["人間語"])
    }

    func test_名前を変えた文字起こしロールがあれば二重に足さない() throws {
        var renamed = RoleStore.transcriptionRole
        renamed.name = "OCR"
        defaults.set(try JSONEncoder().encode([renamed]), forKey: "roles")
        defaults.set(2, forKey: "rolesSchemaVersion")

        let store = RoleStore(defaults: defaults, addsTranscriptionRole: true)
        XCTAssertEqual(store.roles.map(\.name), ["OCR"])
    }
}
