import Foundation
import Observation

@Observable
@MainActor
public final class RoleStore {
    public private(set) var roles: [Role] = []
    private let defaults: UserDefaults
    private let addsTranscriptionRole: Bool

    /// v2: overlay を responsePatterns から additionalResponsePatterns へ移した。
    /// v3: iOS の既存ユーザーにも「文字起こし」ロールを足した。
    /// v4: macOS にも「文字起こし」ロールを足した。v3 の macOS は足さずに移行済みなので、番号を分けた。
    private static let schemaVersion = 4
    private static let schemaVersionKey = "rolesSchemaVersion"

    /// 画像の文字はコピーできないので、スクリーンショットやキャプチャからの書き起こしを既定で使えるようにする。
    public nonisolated static var addsTranscriptionRoleByDefault: Bool { true }

    public init(defaults: UserDefaults = .standard, addsTranscriptionRole: Bool = RoleStore.addsTranscriptionRoleByDefault) {
        self.defaults = defaults
        self.addsTranscriptionRole = addsTranscriptionRole
        load()
    }

    private var initialRoles: [Role] {
        addsTranscriptionRole ? Self.presets + [Self.transcriptionRole] : Self.presets
    }

    public func load() {
        guard let data = defaults.data(forKey: "roles") else {
            roles = initialRoles
            save()
            defaults.set(Self.schemaVersion, forKey: Self.schemaVersionKey)
            print("[RoleStore] No saved roles, using presets")
            return
        }
        do {
            roles = try JSONDecoder().decode([Role].self, from: data)
            print("[RoleStore] Loaded \(roles.count) roles from UserDefaults")
            migrateIfNeeded(original: data)
        } catch {
            // 読めないだけで消してしまうと、利用者のプロンプトが二度と戻らない。
            let backupKey = "roles.unreadable.\(Int(Date().timeIntervalSince1970))"
            defaults.set(data, forKey: backupKey)
            roles = initialRoles
            print("[RoleStore] Could not decode roles, kept a copy at \(backupKey): \(error)")
        }
    }

    /// 形式を変えるときは schemaVersion を上げる。移行前の原本は消さずに残す。
    private func migrateIfNeeded(original: Data) {
        let stored = defaults.integer(forKey: Self.schemaVersionKey)
        guard stored < Self.schemaVersion else { return }
        let backupKey = "roles.backup.v\(stored)"
        if defaults.data(forKey: backupKey) == nil {
            defaults.set(original, forKey: backupKey)
        }
        // 名前を変えていても同じロールとわかるよう、固定の ID でも照合する。消したロールを毎回足し直さないよう、足すのは v4 への移行の一度だけ。
        if stored < 4, addsTranscriptionRole,
           !roles.contains(where: { $0.id == Self.transcriptionRole.id || $0.name == Self.transcriptionRole.name }) {
            roles.append(Self.transcriptionRole)
        }
        save()
        defaults.set(Self.schemaVersion, forKey: Self.schemaVersionKey)
        print("[RoleStore] Migrated roles from schema v\(stored) to v\(Self.schemaVersion)")
    }

    public func save() {
        if let data = try? JSONEncoder().encode(roles) {
            defaults.set(data, forKey: "roles")
            defaults.synchronize()
            print("[RoleStore] Saved \(roles.count) roles")
        }
    }

    public func add(_ role: Role) {
        roles.append(role)
        save()
    }

    public func update(_ role: Role) {
        guard let index = roles.firstIndex(where: { $0.id == role.id }) else { return }
        roles[index] = role
        save()
    }

    public func delete(_ role: Role) {
        roles.removeAll { $0.id == role.id }
        save()
    }

    public func move(fromOffsets: IndexSet, toOffset: Int) {
        roles.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    public static let transcriptionRole = Role(
        id: UUID(uuidString: "5F0B7C9E-2D41-4A8B-9C63-7E1D2A4B8F10")!,
        name: "文字起こし",
        icon: "✍️",
        systemPrompt: "与えられた画像やテキストに書かれている文字を、そのまま書き起こしてください。要約・翻訳・言い換えはしないでください。改行や箇条書きなど元の構成はできるだけ保ち、読み取れない箇所は［判読不能］と書いてください。書き起こした本文だけを返してください。",
        responsePatterns: [.richMessage]
    )

    public static let presets: [Role] = [
        Role(
            name: "英訳",
            icon: "🌐",
            systemPrompt: "あなたは優秀な翻訳者です。与えられた日本語テキストを自然な英語に翻訳してください。翻訳結果のみを返してください。",
            responsePatterns: [.richMessage]
        ),
        Role(
            name: "和訳",
            icon: "🇯🇵",
            systemPrompt: "あなたは優秀な翻訳者です。与えられた英語テキストを自然な日本語に翻訳してください。翻訳結果のみを返してください。",
            responsePatterns: [.richMessage]
        ),
        Role(
            name: "メール返信",
            icon: "✉️",
            systemPrompt: "あなたはビジネスメールの専門家です。与えられたメール内容を読み取り、適切な返信文を日本語で生成してください。丁寧で簡潔な文面にしてください。",
            responsePatterns: [.richMessage]
        ),
        Role(
            name: "要約",
            icon: "📝",
            systemPrompt: "与えられたテキストの内容を簡潔に要約してください。要点を箇条書きで示してください。",
            responsePatterns: [.richMessage]
        ),
    ]
}
