import Foundation

public enum ResponsePattern: String, Codable, CaseIterable, Sendable {
    case richMessage
    case clipboard
}

public enum ImageInputMode: String, Codable, CaseIterable, Sendable {
    case image
    case ocr
}

public struct Role: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var icon: String
    public var systemPrompt: String
    public var responsePatterns: [ResponsePattern]
    public var modelId: UUID?
    public var imageInputMode: ImageInputMode

    public init(
        id: UUID = UUID(),
        name: String,
        icon: String,
        systemPrompt: String,
        responsePatterns: [ResponsePattern],
        modelId: UUID? = nil,
        imageInputMode: ImageInputMode = .image
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.systemPrompt = systemPrompt
        self.responsePatterns = responsePatterns
        self.modelId = modelId
        self.imageInputMode = imageInputMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        responsePatterns = try container.decode([ResponsePattern].self, forKey: .responsePatterns)
        modelId = try container.decodeIfPresent(UUID.self, forKey: .modelId)
        imageInputMode = try container.decodeIfPresent(ImageInputMode.self, forKey: .imageInputMode) ?? .image
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, systemPrompt, responsePatterns, modelId, imageInputMode
    }
}
