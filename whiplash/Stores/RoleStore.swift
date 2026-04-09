import Foundation
import Observation

@Observable
final class RoleStore {
    private(set) var roles: [Role] = []

    init() {
        load()
    }

    func load() {
        if let data = UserDefaults.standard.data(forKey: "roles"),
           let decoded = try? JSONDecoder().decode([Role].self, from: data) {
            roles = decoded
            print("[RoleStore] Loaded \(roles.count) roles from UserDefaults")
        } else {
            roles = Self.presets
            save()
            print("[RoleStore] No saved roles, using presets")
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(roles) {
            UserDefaults.standard.set(data, forKey: "roles")
            UserDefaults.standard.synchronize()
            print("[RoleStore] Saved \(roles.count) roles")
        }
    }

    func add(_ role: Role) {
        roles.append(role)
        save()
    }

    func update(_ role: Role) {
        guard let index = roles.firstIndex(where: { $0.id == role.id }) else { return }
        roles[index] = role
        save()
    }

    func delete(_ role: Role) {
        roles.removeAll { $0.id == role.id }
        save()
    }

    static let presets: [Role] = [
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
