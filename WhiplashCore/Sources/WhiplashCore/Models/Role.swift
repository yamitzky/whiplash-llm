import Foundation

public enum ResponsePattern: String, Codable, CaseIterable, Sendable {
    case richMessage
    case clipboard
    case overlay
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

    /// 結果は常にボックスで見せ、コピーするかだけをロールで選ぶ。
    /// richMessage を外すとボックスが出ずにトーストだけで終わり、結果を見失うため。
    /// 古いビルドが同じデータを読んでもボックスを出すよう、richMessage は常に書く。
    public var copiesToClipboard: Bool {
        get { responsePatterns.contains(.clipboard) }
        set { responsePatterns = newValue ? [.richMessage, .clipboard] : [.richMessage] }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        // 別のバージョンが保存した未知の値で全ロールの読み込みを失敗させない。
        let stored = try container.decode([String].self, forKey: .responsePatterns)
        let additional = try container.decodeIfPresent([String].self, forKey: .additionalResponsePatterns) ?? []
        var patterns: [ResponsePattern] = []
        for pattern in (stored + additional).compactMap(ResponsePattern.init(rawValue:)) where !patterns.contains(pattern) {
            patterns.append(pattern)
        }
        responsePatterns = patterns
        modelId = try container.decodeIfPresent(UUID.self, forKey: .modelId)
        // 未知の値で全ロールの読み込みを失敗させない。既定へ戻るのは、このロールの入力方式だけで済む。
        imageInputMode = (try container.decodeIfPresent(String.self, forKey: .imageInputMode))
            .flatMap(ImageInputMode.init(rawValue:)) ?? .image
    }

    /// 古いビルドは responsePatterns の未知の値で全ロールの読み込みに失敗し、プリセットで上書きする。
    /// そのビルドが同じ保存先を読んでも壊れないよう、後から足した値は別のキーに分けて書く。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(icon, forKey: .icon)
        try container.encode(systemPrompt, forKey: .systemPrompt)
        try container.encode(responsePatterns.filter { !Self.additionalPatterns.contains($0) }, forKey: .responsePatterns)
        let additional = responsePatterns.filter { Self.additionalPatterns.contains($0) }
        if !additional.isEmpty {
            try container.encode(additional, forKey: .additionalResponsePatterns)
        }
        try container.encodeIfPresent(modelId, forKey: .modelId)
        try container.encode(imageInputMode, forKey: .imageInputMode)
    }

    private static let additionalPatterns: Set<ResponsePattern> = [.overlay]

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, systemPrompt, responsePatterns, additionalResponsePatterns, modelId, imageInputMode
    }
}
