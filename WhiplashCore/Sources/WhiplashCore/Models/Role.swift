import Foundation

public enum ResponsePattern: String, Codable, CaseIterable, Sendable {
    case richMessage
    case clipboard
}

public struct Role: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var icon: String
    public var systemPrompt: String
    public var responsePatterns: [ResponsePattern]
    public var modelId: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        icon: String,
        systemPrompt: String,
        responsePatterns: [ResponsePattern],
        modelId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.systemPrompt = systemPrompt
        self.responsePatterns = responsePatterns
        self.modelId = modelId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        responsePatterns = try container.decode([ResponsePattern].self, forKey: .responsePatterns)
        modelId = try container.decodeIfPresent(UUID.self, forKey: .modelId)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, systemPrompt, responsePatterns, modelId
    }
}
