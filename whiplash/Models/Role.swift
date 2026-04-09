import Foundation

enum ResponsePattern: String, Codable, CaseIterable {
    case richMessage
    case clipboard
}

struct Role: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var icon: String
    var systemPrompt: String
    var responsePatterns: [ResponsePattern]
    var modelId: UUID?

    init(
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

    // Support decoding from old format that had backendOverride
    init(from decoder: Decoder) throws {
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
